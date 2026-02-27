#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

usage() {
  cat <<'EOF'
Usage:
  ./examples/check_etcd_connectivity.sh
  ./examples/check_etcd_connectivity.sh --self-test success|failure
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

KUBE_ETCD_COUNT="${KUBE_ETCD_COUNT:-3}"

failures=0
endpoints="$(./scripts/resolve_etcd_endpoints.sh --format endpoints)"
echo "Checking etcd cluster via endpoints: ${endpoints}"

if remote "etcd1" "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint health" >/dev/null 2>&1; then
  echo "[OK]   endpoint health check"
else
  echo "[FAIL] endpoint health check"
  failures=$((failures + 1))
fi

member_list="$(remote "etcd1" "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} member list" 2>/dev/null || true)"
member_count="$(printf '%s\n' "${member_list}" | sed '/^$/d' | wc -l | tr -dc '0-9')"
[[ -n "${member_count}" ]] || member_count=0

if [[ "${member_count}" -eq "${KUBE_ETCD_COUNT}" ]]; then
  echo "[OK]   member count (${member_count}/${KUBE_ETCD_COUNT})"
else
  echo "[FAIL] member count (${member_count}/${KUBE_ETCD_COUNT})"
  failures=$((failures + 1))
fi

status_json="$(remote "etcd1" "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint status -w json" 2>/dev/null || true)"
unique_ids=0
leader_count=0
if [[ -n "${status_json}" ]]; then
  unique_ids="$(printf '%s' "${status_json}" | ./scripts/parse_etcd_endpoint_status.sh --field unique_ids || true)"
  leader_count="$(printf '%s' "${status_json}" | ./scripts/parse_etcd_endpoint_status.sh --field leaders || true)"
  [[ -n "${leader_count}" ]] || leader_count=0
fi

if [[ "${unique_ids}" -eq "${KUBE_ETCD_COUNT}" ]]; then
  echo "[OK]   unique member IDs (${unique_ids}/${KUBE_ETCD_COUNT})"
else
  echo "[FAIL] unique member IDs (${unique_ids}/${KUBE_ETCD_COUNT})"
  failures=$((failures + 1))
fi

if [[ "${leader_count}" -eq 1 ]]; then
  echo "[OK]   single leader detected"
else
  echo "[FAIL] expected one leader, got ${leader_count}"
  failures=$((failures + 1))
fi

echo "Checking etcd peer network reachability (tcp/2379 and tcp/2380)"
while read -r src_name _; do
  while read -r dst_name dst_ip; do
    if [[ "${src_name}" == "${dst_name}" ]]; then
      continue
    fi
    if remote "${src_name}" "timeout 2 bash -lc '</dev/tcp/${dst_ip}/2379' >/dev/null 2>&1"; then
      echo "[OK]   ${src_name} -> ${dst_name} tcp/2379"
    else
      echo "[FAIL] ${src_name} -> ${dst_name} tcp/2379"
      failures=$((failures + 1))
    fi
    if remote "${src_name}" "timeout 2 bash -lc '</dev/tcp/${dst_ip}/2380' >/dev/null 2>&1"; then
      echo "[OK]   ${src_name} -> ${dst_name} tcp/2380"
    else
      echo "[FAIL] ${src_name} -> ${dst_name} tcp/2380"
      failures=$((failures + 1))
    fi
  done < <(./scripts/resolve_etcd_endpoints.sh --format nodes)
done < <(./scripts/resolve_etcd_endpoints.sh --format nodes)

if [[ "${failures}" -gt 0 ]]; then
  echo "etcd connectivity check failed: ${failures} failed probe(s)."
  exit 1
fi

echo "etcd connectivity check passed."
