#!/usr/bin/env bash
set -euo pipefail

KUBECONFIG_PATH="${1:-/etc/kubernetes/admin.conf}"
NODE_NAME="${NODE_NAME:-cp1}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-${2:-600}}"
POLL_SECONDS="${POLL_SECONDS:-${3:-5}}"

required_files=(
  /vagrant/.cluster/ready
  /vagrant/.cluster/join.sh
  /vagrant/.cluster/certificate-key
  /vagrant/.cluster/admin.conf
)

for f in "${required_files[@]}"; do
  if [[ ! -s "${f}" ]]; then
    echo "cp1 readiness check: missing/empty ${f}" >&2
    exit 1
  fi
done

export KUBECONFIG="${KUBECONFIG_PATH}"
start_ts="$(date +%s)"
while true; do
  if kubectl get --raw='/readyz?verbose' >/dev/null 2>&1; then
    break
  fi
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo "cp1 readiness check: apiserver not ready after ${elapsed}s" >&2
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done

while true; do
  node_ready="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${node_ready}" == "True" ]]; then
    break
  fi
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed >= TIMEOUT_SECONDS )); then
    echo "cp1 readiness check: node ${NODE_NAME} not Ready after ${elapsed}s" >&2
    kubectl get node "${NODE_NAME}" -o wide || true
    exit 1
  fi
  sleep "${POLL_SECONDS}"
done

echo "cp1 readiness check: OK"
