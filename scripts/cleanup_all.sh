#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-cluster}"
PROJECT_PREFIX="${2:-ffreis-k8s-vagrant-lab_}"
STRICT="${STRICT:-false}"
VAGRANT_RUN="${ROOT_DIR}/scripts/vagrant_retry.sh"

cleanup_locks() {
  find "${ROOT_DIR}/.vagrant" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
  find "${HOME}/.vagrant.d/data/machine-index" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
}

cleanup_cluster() {
  cleanup_locks
  # Pre-clean orphan libvirt resources first; this avoids vagrant-libvirt
  # collisions like "domain name already taken" during destroy.
  "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "${PROJECT_PREFIX}" "${KUBE_NETWORK_PREFIX:-}" || true
  run_destroy_quiet api-lb || true
  run_destroy_quiet || true
  # Post-clean again to remove anything left outside Vagrant state.
  "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "${PROJECT_PREFIX}" "${KUBE_NETWORK_PREFIX:-}" || true
  rm -rf "${ROOT_DIR}/.cluster" "${ROOT_DIR}/.vagrant" "${ROOT_DIR}/.vagrant-nodes.json"
  if [[ "${STRICT}" == "true" ]] && command -v virsh >/dev/null 2>&1; then
    if virsh list --all --name | grep -q "^${PROJECT_PREFIX}"; then
      echo "Strict cleanup failed: libvirt domains still present for prefix ${PROJECT_PREFIX}" >&2
      return 1
    fi
  fi
}

cleanup_bake() {
  cleanup_locks
  if [[ -d "${ROOT_DIR}/.bake/basebox" ]]; then
    (
      cd "${ROOT_DIR}/.bake/basebox"
      run_destroy_quiet box-bake || true
      run_destroy_quiet || true
    ) || true
  fi
  rm -rf "${ROOT_DIR}/.bake/basebox"
}

run_destroy_quiet() {
  local tmp_file rc
  tmp_file="$(mktemp)"
  rc=0
  if [[ $# -gt 0 ]]; then
    "${VAGRANT_RUN}" vagrant destroy -f "$@" >"${tmp_file}" 2>&1 || rc=$?
  else
    "${VAGRANT_RUN}" vagrant destroy -f >"${tmp_file}" 2>&1 || rc=$?
  fi

  # Hide known non-fatal destroy noise, keep everything else visible.
  sed -E \
    -e '/^\[fog\]\[WARNING\].*libvirt_ip_command.*$/d' \
    -e '/Domain is not created\. Please run `vagrant up` first\./d' \
    "${tmp_file}"

  rm -f "${tmp_file}"
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
