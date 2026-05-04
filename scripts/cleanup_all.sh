#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-cluster}"
PROJECT_PREFIX="${2:-ffreis-k8s-vagrant-lab_}"
STRICT="${STRICT:-false}"
VAGRANT_RUN="${ROOT_DIR}/scripts/vagrant_retry.sh"
DESTROY_TIMEOUT_SECONDS="${KUBE_DESTROY_TIMEOUT_SECONDS:-300}"

log() {
  echo "[cleanup] $*"
}

cleanup_locks() {
  log "clearing stale local lock files"
  find "${ROOT_DIR}/.vagrant" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
  find "${HOME}/.vagrant.d/data/machine-index" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
}

cleanup_cluster() {
  cleanup_locks
  # Pre-clean orphan libvirt resources first; this avoids vagrant-libvirt
  # collisions like "domain name already taken" during destroy.
  log "pre-cleaning libvirt resources for prefix ${PROJECT_PREFIX}"
  "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "${PROJECT_PREFIX}" "${KUBE_NETWORK_PREFIX:-}" || true
  log "destroying api-lb (best-effort)"
  run_destroy_quiet api-lb || true
  log "destroying all Vagrant machines (best-effort)"
  run_destroy_quiet || true
  # Post-clean again to remove anything left outside Vagrant state.
  log "post-cleaning libvirt resources for prefix ${PROJECT_PREFIX}"
  "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "${PROJECT_PREFIX}" "${KUBE_NETWORK_PREFIX:-}" || true
  log "removing local state directories"
  rm -rf "${ROOT_DIR}/.cluster" "${ROOT_DIR}/.vagrant" "${ROOT_DIR}/.vagrant-nodes.json"
  if [[ "${STRICT}" == "true" ]] && command -v virsh >/dev/null 2>&1; then
    log "strict mode enabled: verifying no residual libvirt domains"
    if virsh list --all --name | grep -q "^${PROJECT_PREFIX}"; then
      echo "Strict cleanup failed: libvirt domains still present for prefix ${PROJECT_PREFIX}" >&2
      return 1
    fi
  fi
  log "cluster cleanup complete"
}

cleanup_bake() {
  cleanup_locks
  if [[ -d "${ROOT_DIR}/.bake/basebox" ]]; then
    log "destroying bake environment VMs (best-effort)"
    (
      cd "${ROOT_DIR}/.bake/basebox"
      run_destroy_quiet box-bake || true
      run_destroy_quiet || true
    ) || true
  fi
  log "removing bake workspace"
  rm -rf "${ROOT_DIR}/.bake/basebox"
  log "bake cleanup complete"
}

run_destroy_quiet() {
  local tmp_file rc start_ts elapsed
  tmp_file="$(mktemp)"
  rc=0
  start_ts="$(date +%s)"
  log "running: vagrant destroy -f $* (timeout=${DESTROY_TIMEOUT_SECONDS}s)"
  if [[ $# -gt 0 ]]; then
    timeout --foreground "${DESTROY_TIMEOUT_SECONDS}" "${VAGRANT_RUN}" vagrant destroy -f "$@" >"${tmp_file}" 2>&1 || rc=$?
  else
    timeout --foreground "${DESTROY_TIMEOUT_SECONDS}" "${VAGRANT_RUN}" vagrant destroy -f >"${tmp_file}" 2>&1 || rc=$?
  fi
  elapsed="$(( $(date +%s) - start_ts ))"

  # Hide known non-fatal destroy noise, keep everything else visible.
  sed -E \
    -e '/^\[fog\]\[WARNING\].*libvirt_ip_command.*$/d' \
    -e '/Domain is not created\. Please run `vagrant up` first\./d' \
    "${tmp_file}"

  rm -f "${tmp_file}"
  if [[ "${rc}" -eq 124 ]]; then
    echo "[cleanup] ERROR: destroy timed out after ${elapsed}s (set KUBE_DESTROY_TIMEOUT_SECONDS to override)" >&2
  else
    log "destroy command finished in ${elapsed}s (rc=${rc})"
  fi
  return "${rc}"
}

case "${MODE}" in
  cluster)
    cleanup_cluster
    ;;
  bake)
    cleanup_bake
    ;;
  all)
    cleanup_bake
    cleanup_cluster
    ;;
  *)
    echo "Usage: $0 [cluster|bake|all] [project-prefix]" >&2
    exit 2
    ;;
esac
