#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(pwd)/.cluster/admin.conf}"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "Missing kubeconfig at ${KUBECONFIG_PATH}. Run 'make kubeconfig' first." >&2
  exit 1
fi

kc() {
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
}

etcd_status_row_for_pod() {
  local pod_name="$1"
  local output row

  output="$(
    kc -n kube-system exec "${pod_name}" -- sh -lc '
      ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        endpoint status --write-out=table
    ' 2>/dev/null || true
  )"
  row="$(printf '%s\n' "${output}" | awk '/127\.0\.0\.1:2379/ {print; exit}')"
  printf '%s\n' "${row}"
}

print_leader_snapshot() {
  local pod node row leader learner
  local found=0

  echo "[etcd] leader snapshot"
  for pod in $(kc -n kube-system get pods -l component=etcd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    node="$(kc -n kube-system get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
    row="$(etcd_status_row_for_pod "${pod}")"

    if [[ -z "${row}" ]]; then
      printf '%-12s %-10s leader=%s learner=%s\n' "${pod}" "${node}" "unknown" "unknown"
      continue
    fi

    leader="$(awk '{print $5}' <<<"${row}")"
    learner="$(awk '{print $6}' <<<"${row}")"
    printf '%-12s %-10s leader=%s learner=%s\n' "${pod}" "${node}" "${leader}" "${learner}"
    if [[ "${leader}" == "true" ]]; then
      found=1
    fi
  done

  if [[ "${found}" -eq 0 ]]; then
    echo "No etcd leader detected from local endpoint checks." >&2
    return 1
  fi
}

case "${MODE}" in
  status)
    echo "[control-plane] nodes"
    kc get nodes -l node-role.kubernetes.io/control-plane -o wide
    print_leader_snapshot
    ;;
  leader)
    print_leader_snapshot | awk '/leader=true/ {print}'
    ;;
  *)
    echo "Usage: $0 [status|leader]" >&2
    exit 1
    ;;
esac
