#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAGRANT_RUN="${ROOT_DIR}/scripts/vagrant_retry.sh"
MODE="${1:-full}" # full|infra|workers
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/state.sh"

log_phase() {
  echo "[phase] $*"
}

cp1_wait_timeout_seconds() {
  local join_wait init_wait min_wait
  join_wait="${KUBE_JOIN_MAX_WAIT_SECONDS:-1200}"
  init_wait="${KUBE_CP1_INIT_TIMEOUT_SECONDS:-1800}"
  min_wait=$((init_wait + 300))
  if (( join_wait < min_wait )); then
    echo "${min_wait}"
  else
    echo "${join_wait}"
  fi
}

run_vagrant() {
  "${VAGRANT_RUN}" vagrant "$@"
}

ensure_vm() {
  local machine="$1" expected_host="$2" expected_ip="$3" expected_cpus="$4" expected_mem="$5" expected_role="$6"
  local out_file rc machine_prefix net_prefix attempt max_attempts
  out_file="$(mktemp)"
  machine_prefix="ffreis-k8s-vagrant-lab_${machine}"
  net_prefix="${expected_ip%.*}"
  max_attempts=3
  rc=0
  for attempt in $(seq 1 "${max_attempts}"); do
    rc=0
    "${VAGRANT_RUN}" vagrant up "${machine}" --provider "${KUBE_PROVIDER}" --no-provision >"${out_file}" 2>&1 || rc=$?
    cat "${out_file}"
    if [[ "${rc}" -eq 0 ]]; then
      break
    fi
    if grep -Eq "Volume for domain is already created|Name .+ of domain about to create is already taken" "${out_file}"; then
      echo "[ensure-vm] stale libvirt resources for ${machine}; cleanup and retry ${attempt}/${max_attempts}" >&2
      "${VAGRANT_RUN}" vagrant destroy -f "${machine}" >/dev/null 2>&1 || true
      rm -rf ".vagrant/machines/${machine}" || true
      "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "${machine_prefix}" "${net_prefix}" || true
      sleep 2
      continue
    fi
    break
  done

  rm -f "${out_file}"
  if [[ "${rc}" -ne 0 ]]; then
    return "${rc}"
  fi

  "${ROOT_DIR}/scripts/ensure_node_identity.sh" "${machine}" "${expected_host}" "${expected_ip}" "${KUBE_PROVIDER}" "${expected_cpus}" "${expected_mem}" "${expected_role}"
}

provision_named() {
  local machine="$1" names="$2"
  run_vagrant provision "${machine}" --provision-with "${names}"
}

provision_workers_parallel() {
  local names="$1"
  local concurrency="${KUBE_WORKER_PARALLELISM:-2}"
  local workers=()
  local i

  for i in $(seq 1 "${KUBE_WORKER_COUNT}"); do
    workers+=("worker${i}")
  done

  if [[ "${#workers[@]}" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "${workers[@]}" | xargs -P "${concurrency}" -I{} bash -lc '
    set -euo pipefail
    "'"${VAGRANT_RUN}"'" vagrant provision "{}" --provision-with "'"${names}"'"
  '
}

log_phase "preflight"
"${ROOT_DIR}/scripts/preflight.sh"

log_phase "state-init"
cd "${ROOT_DIR}"
mkdir -p "${ROOT_DIR}/.cluster"
if [[ "${MODE}" == "full" || "${MODE}" == "infra" ]]; then
  rm -f "${ROOT_DIR}/.cluster/ready" "${ROOT_DIR}/.cluster/failed"
  state_init
  state_set TOPOLOGY "cp=${KUBE_CP_COUNT},worker=${KUBE_WORKER_COUNT},api_lb=${KUBE_API_LB_ENABLED}"
fi

log_phase "infra-up"
if [[ "${MODE}" == "full" || "${MODE}" == "infra" ]]; then
  if [[ "${KUBE_API_LB_ENABLED:-true}" == "true" ]]; then
    ensure_vm "api-lb" "api-lb" "${KUBE_API_LB_IP}" "${KUBE_API_LB_CPUS}" "${KUBE_API_LB_MEMORY}" "api-lb"
    provision_named "api-lb" "api-lb"
  fi

  ensure_vm "cp1" "cp1" "${KUBE_NETWORK_PREFIX}.11" "${KUBE_CP_CPUS}" "${KUBE_CP_MEMORY}" "control-plane"
  provision_named "cp1" "base-common,cp-init"
  "${ROOT_DIR}/scripts/wait_remote_artifact.sh" cp1 /vagrant/.cluster/ready "$(cp1_wait_timeout_seconds)" "${KUBE_JOIN_POLL_SECONDS:-5}"
  run_vagrant ssh cp1 -c "sudo /vagrant/scripts/check_cp1_ready.sh /etc/kubernetes/admin.conf ${KUBE_CP_STABILIZE_TIMEOUT_SECONDS:-900} ${KUBE_CP_STABILIZE_POLL_SECONDS:-5}"

  run_vagrant ssh cp1 -c 'sudo cat /vagrant/.cluster/join.sh' | tr -d '\r' > .cluster/join.sh
  run_vagrant ssh cp1 -c 'sudo cat /vagrant/.cluster/certificate-key' | tr -d '\r' > .cluster/certificate-key
  run_vagrant ssh cp1 -c 'sudo cat /vagrant/.cluster/admin.conf' | tr -d '\r' > .cluster/admin.conf
  chmod 600 .cluster/join.sh .cluster/certificate-key .cluster/admin.conf
  touch .cluster/ready

  "${ROOT_DIR}/scripts/wait_control_plane_stable.sh" cp1 1

  if [[ "${KUBE_CP_COUNT}" -gt 1 ]]; then
    for i in $(seq 2 "${KUBE_CP_COUNT}"); do
      cp="cp${i}"
      ensure_vm "${cp}" "${cp}" "${KUBE_NETWORK_PREFIX}.$((10 + i))" "${KUBE_CP_CPUS}" "${KUBE_CP_MEMORY}" "control-plane"
      provision_named "${cp}" "base-common,cp-join"
      "${ROOT_DIR}/scripts/wait_control_plane_stable.sh" "${cp}" "${i}"
    done
  fi
fi

if [[ "${MODE}" == "full" || "${MODE}" == "workers" ]] && [[ "${KUBE_WORKER_COUNT}" -gt 0 ]]; then
  log_phase "workers-up"
  for i in $(seq 1 "${KUBE_WORKER_COUNT}"); do
    wk="worker${i}"
    ensure_vm "${wk}" "${wk}" "${KUBE_NETWORK_PREFIX}.$((100 + i))" "${KUBE_WORKER_CPUS}" "${KUBE_WORKER_MEMORY}" "worker"
  done

  log_phase "workers-base-parallel"
  provision_workers_parallel "base-common"

  log_phase "workers-join-parallel"
  provision_workers_parallel "worker-join"
fi

log_phase "kubeconfig"
mkdir -p .cluster
run_vagrant ssh cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > .cluster/admin.conf
chmod 600 .cluster/admin.conf

state_set STATUS complete
state_set COMPLETED_AT "$(date -Iseconds)"

echo "[phase] up-flow complete"
