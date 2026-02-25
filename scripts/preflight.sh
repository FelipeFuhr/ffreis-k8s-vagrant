#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/preflight.sh"

fail=0
autoclean_libvirt="${KUBE_PREFLIGHT_AUTOCLEAN_LIBVIRT:-true}"

need_cpu="$(required_cpu_count)"
need_mem_gib="$(required_mem_gib)"
have_cpu="$(host_cpu_count)"
have_mem_gib="$(host_mem_gib)"

echo "[preflight] host cpu=${have_cpu} required>=${need_cpu}"
echo "[preflight] host mem_gib=${have_mem_gib} required>=${need_mem_gib}"

if (( have_cpu < need_cpu )); then
  echo "[preflight] ERROR: insufficient host CPU for requested topology" >&2
  fail=1
fi

if (( have_mem_gib < need_mem_gib )); then
  echo "[preflight] ERROR: insufficient host memory for requested topology" >&2
  fail=1
fi

if conflict_msg="$(cidr_conflicts_host_routes)"; then
  if [[ "${autoclean_libvirt}" == "true" ]] && [[ "${KUBE_PROVIDER:-libvirt}" == "libvirt" ]]; then
    echo "[preflight] route conflict detected; attempting stale libvirt cleanup for ${KUBE_NETWORK_PREFIX}.0/24" >&2
    "${ROOT_DIR}/scripts/libvirt_cleanup.sh" "ffreis-k8s-vagrant-lab_" "${KUBE_NETWORK_PREFIX}" || true
    sleep 2
    if conflict_msg="$(cidr_conflicts_host_routes)"; then
      echo "[preflight] ERROR: ${conflict_msg}" >&2
      suggestion="$(suggest_free_network_prefix)"
      echo "[preflight] Suggestion: KUBE_NETWORK_PREFIX=${suggestion} KUBE_API_LB_IP=${suggestion}.5 make up" >&2
      fail=1
    else
      echo "[preflight] stale route conflict auto-cleaned" >&2
    fi
  else
    echo "[preflight] ERROR: ${conflict_msg}" >&2
    suggestion="$(suggest_free_network_prefix)"
    echo "[preflight] Suggestion: KUBE_NETWORK_PREFIX=${suggestion} KUBE_API_LB_IP=${suggestion}.5 make up" >&2
    fail=1
  fi
fi

if [[ "${fail}" -ne 0 ]]; then
  exit 1
fi

echo "[preflight] OK"
