#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <machine> <expected-hostname> <expected-ip> <provider> [expected-cpus] [expected-memory-mib] [expected-role]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_RETRY="${SCRIPT_DIR}/vagrant_retry.sh"
VERIFY="${SCRIPT_DIR}/verify_node_identity.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/node_contract.sh"

machine="${1}"
expected_host="${2}"
expected_ip="${3}"
provider="${4}"
expected_cpus="${5:-}"
expected_memory_mib="${6:-}"
expected_role="${7:-}"
project_prefix="ffreis-k8s-vagrant-lab_"
net_prefix="${expected_ip%.*}"

soft_fix_hostname() {
  "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "sudo hostnamectl set-hostname '${expected_host}' && echo '${expected_host}' | sudo tee /etc/hostname >/dev/null" >/dev/null 2>&1 || return 1
  sleep 1
  "${VERIFY}" "${machine}" "${expected_host}" "${expected_ip}" >/dev/null 2>&1
}

hostname_mismatch() {
  local actual_host
  actual_host="$(node_actual_hostname "${machine}" "${VAGRANT_RETRY}" || true)"
  [[ -n "${actual_host}" && "${actual_host}" != "${expected_host}" ]]
}

node_has_lb_ip_conflict() {
  local lb_ip
  lb_ip="${net_prefix}.5/24"
  [[ "${machine}" == "api-lb" ]] && return 1
  "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "ip -o -4 addr show | awk '{print \$4}' | grep -qx '${lb_ip}'" >/dev/null 2>&1
}

mapping_looks_wrong() {
  local id_file machine_id dom_name
  id_file=".vagrant/machines/${machine}/${provider}/id"
  if [[ ! -f "${id_file}" ]]; then
    return 1
  fi
  machine_id="$(tr -d '\r\n' <"${id_file}")"
  if [[ -z "${machine_id}" ]]; then
    return 1
  fi
  if ! command -v virsh >/dev/null 2>&1; then
    return 1
  fi
  dom_name="$(virsh domname "${machine_id}" 2>/dev/null || true)"
  if [[ -z "${dom_name}" ]]; then
    return 1
  fi
  [[ "${dom_name}" != *"_${machine}" ]]
}

if mapping_looks_wrong; then
  echo "[ensure-node] local machine-id mapping for ${machine} appears stale; resetting local mapping" >&2
  rm -rf ".vagrant/machines/${machine}" || true
fi

resource_or_role_mismatch() {
  local actual_cpus actual_mem_mib
  if ! "${VERIFY}" "${machine}" "${expected_host}" "${expected_ip}" >/dev/null 2>&1; then
    return 0
  fi

  if [[ -n "${expected_cpus}" ]]; then
    actual_cpus="$(node_actual_cpu_count "${machine}" "${VAGRANT_RETRY}" || true)"
    if [[ -z "${actual_cpus}" || "${actual_cpus}" -lt "${expected_cpus}" ]]; then
      echo "[ensure-node] CPU mismatch for ${machine}: expected >=${expected_cpus}, got ${actual_cpus:-unknown}" >&2
      return 0
    fi
  fi

  if [[ -n "${expected_memory_mib}" ]]; then
    actual_mem_mib="$(node_actual_memory_mib "${machine}" "${VAGRANT_RETRY}" || true)"
    if [[ -z "${actual_mem_mib}" || "${actual_mem_mib}" -lt "$((expected_memory_mib - 256))" ]]; then
      echo "[ensure-node] memory mismatch for ${machine}: expected around ${expected_memory_mib}MiB, got ${actual_mem_mib:-unknown}MiB" >&2
      return 0
    fi
  fi

  if [[ "${expected_role}" == "control-plane" ]]; then
    if "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "sudo ss -ltn '( sport = :6443 )' | grep -q ':6443'" >/dev/null 2>&1 \
      && node_haproxy_active "${machine}" "${VAGRANT_RETRY}"; then
      echo "[ensure-node] role mismatch for ${machine}: haproxy active on control-plane candidate" >&2
      return 0
    fi
  fi

  return 1
}

recreate_machine() {
  local out_file rc machine_prefix attempt max_attempts
  out_file="$(mktemp)"
  machine_prefix="${project_prefix}${machine}"
  max_attempts=3

  "${VAGRANT_RETRY}" vagrant destroy -f "${machine}" || true
  rm -rf ".vagrant/machines/${machine}" || true

  rc=0
  for attempt in $(seq 1 "${max_attempts}"); do
    rc=0
    "${VAGRANT_RETRY}" vagrant up "${machine}" --provider "${provider}" --no-provision >"${out_file}" 2>&1 || rc=$?
    cat "${out_file}"
    if [[ "${rc}" -eq 0 ]]; then
      break
    fi
    if grep -Eq "Name .+ of domain about to create is already taken|Volume for domain is already created" "${out_file}"; then
      echo "[ensure-node] stale libvirt resources detected for ${machine}; cleanup and retry ${attempt}/${max_attempts}" >&2
      "${SCRIPT_DIR}/libvirt_cleanup.sh" "${machine_prefix}" "${net_prefix}" || true
      sleep 2
      continue
    fi
    break
  done
  rm -f "${out_file}"
  return "${rc}"
}

reconcile_with_api_lb() {
  echo "[ensure-node] detected ${machine}<->api-lb identity cross-mapping; reconciling both nodes" >&2
  "${VAGRANT_RETRY}" vagrant destroy -f "${machine}" api-lb >/dev/null 2>&1 || true
  rm -rf ".vagrant/machines/${machine}" ".vagrant/machines/api-lb" || true
  "${SCRIPT_DIR}/libvirt_cleanup.sh" "${project_prefix}${machine}" "${net_prefix}" || true
  "${SCRIPT_DIR}/libvirt_cleanup.sh" "${project_prefix}api-lb" "${net_prefix}" || true
  "${VAGRANT_RETRY}" vagrant up api-lb --provider "${provider}" --no-provision >/dev/null 2>&1 || true
}

if ! resource_or_role_mismatch; then
  echo "[verify-node] ${machine} hostname/ip OK (${expected_host}, ${expected_ip})"
  exit 0
fi

if hostname_mismatch && soft_fix_hostname; then
  if ! resource_or_role_mismatch; then
    echo "[ensure-node] ${machine} hostname corrected in-place"
    exit 0
  fi
fi

if node_has_lb_ip_conflict; then
  reconcile_with_api_lb
fi

echo "[ensure-node] identity mismatch detected for ${machine}; recreating VM" >&2
recreate_machine
if ! resource_or_role_mismatch; then
  echo "[ensure-node] ${machine} identity recovered"
  exit 0
fi

echo "[ensure-node] ${machine} still mismatched; resetting local Vagrant machine mappings and retrying once" >&2
rm -rf .vagrant/machines || true
recreate_machine
if ! resource_or_role_mismatch; then
  echo "[ensure-node] ${machine} identity recovered after mapping reset"
  exit 0
fi

"${VERIFY}" "${machine}" "${expected_host}" "${expected_ip}"
exit 1
