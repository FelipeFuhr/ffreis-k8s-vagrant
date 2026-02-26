#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<'EOF'
Usage:
  ./examples/check_control_plane_connectivity.sh
  ./examples/check_control_plane_connectivity.sh --self-test success|failure
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "${1:-}" == "--self-test" ]]; then
  case "${2:-}" in
    success)
      echo "Self-test success path"
      exit 0
      ;;
    failure)
      echo "Self-test failure path"
      exit 1
      ;;
    *)
      echo "Invalid self-test mode: ${2:-<empty>}" >&2
      usage >&2
      exit 2
      ;;
  esac
fi

if [[ -f config/cluster.env ]]; then
  # shellcheck disable=SC1091
  source config/cluster.env
fi

retry() {
  ./scripts/vagrant_retry.sh "$@"
}

remote() {
  local node="$1"
  shift
  retry vagrant ssh "${node}" -c "$*"
}

declare -a cp_nodes=()
declare -A cp_ips=()

discover_cp_nodes() {
  local kube_nodes
  local cp_count_fallback i

  kube_nodes="$(retry vagrant ssh cp1 -c \
    "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null" \
    | tr -d '\r' || true)"

  if [[ -n "${kube_nodes}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      cp_nodes+=("${line#node/}")
    done <<<"${kube_nodes}"
    return 0
  fi

  cp_count_fallback="${KUBE_CP_COUNT:-1}"
  for i in $(seq 1 "${cp_count_fallback}"); do
    cp_nodes+=("cp${i}")
  done
}

discover_cp_nodes

if [[ "${#cp_nodes[@]}" -lt 2 ]]; then
  echo "Need at least 2 control planes to run this check (detected=${#cp_nodes[@]})."
  exit 0
fi

for node in "${cp_nodes[@]}"; do
  ip="$(remote "${node}" "ip -o -4 addr show | awk '\$4 ~ /^10\\.30\\./ {split(\$4,a,\"/\"); print a[1]; exit}'" | tr -d '\r')"
  if [[ -z "${ip}" ]]; then
    echo "[FAIL] Could not detect 10.30.x IP for ${node}"
    exit 1
  fi
  cp_ips["${node}"]="${ip}"
done

echo "Detected control-plane nodes:"
for node in "${cp_nodes[@]}"; do
  echo "- ${node}: ${cp_ips[${node}]}"
done

failures=0

for src in "${cp_nodes[@]}"; do
  for dst in "${cp_nodes[@]}"; do
    if [[ "${src}" == "${dst}" ]]; then
      continue
    fi
    dst_ip="${cp_ips[${dst}]}"

    if remote "${src}" "ping -c 1 -W 1 ${dst_ip} >/dev/null 2>&1"; then
      echo "[OK]   ${src} -> ${dst} ping (${dst_ip})"
    else
      echo "[FAIL] ${src} -> ${dst} ping (${dst_ip})"
      failures=$((failures + 1))
    fi

    if remote "${src}" "timeout 2 bash -lc '</dev/tcp/${dst_ip}/6443' >/dev/null 2>&1"; then
      echo "[OK]   ${src} -> ${dst} tcp/6443 (${dst_ip})"
    else
      echo "[FAIL] ${src} -> ${dst} tcp/6443 (${dst_ip})"
      failures=$((failures + 1))
    fi
  done
done

if [[ "${failures}" -gt 0 ]]; then
  echo "Control-plane connectivity check failed: ${failures} failed probe(s)."
  exit 1
fi

echo "Control-plane connectivity check passed."
