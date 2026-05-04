#!/usr/bin/env bash
set -euo pipefail

CP_COUNT="${KUBE_CP_COUNT:-1}"
WORKER_COUNT="${KUBE_WORKER_COUNT:-2}"
EXPECTED_NODES=$((CP_COUNT + WORKER_COUNT))
READY_TIMEOUT_SECONDS="${KUBE_VALIDATE_READY_TIMEOUT_SECONDS:-${READY_TIMEOUT_SECONDS:-300}}"
READY_POLL_SECONDS="${KUBE_VALIDATE_READY_POLL_SECONDS:-${READY_POLL_SECONDS:-5}}"

if ! command -v vagrant >/dev/null 2>&1; then
  echo "vagrant command not found"
  exit 1
fi

if [[ ! -f .cluster/admin.conf ]]; then
  echo "Missing .cluster/admin.conf. Run 'make kubeconfig' first."
  exit 1
fi

export KUBECONFIG="$(pwd)/.cluster/admin.conf"

echo "[check] node readiness"
waited=0
while true; do
  ready_nodes="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready$/ {count++} END {print count+0}')"
  if [[ "${ready_nodes}" -ge "${EXPECTED_NODES}" ]]; then
    break
  fi

  if [[ "${waited}" -ge "${READY_TIMEOUT_SECONDS}" ]]; then
    echo "Expected ${EXPECTED_NODES} Ready nodes, got ${ready_nodes} after ${READY_TIMEOUT_SECONDS}s"
    kubectl get nodes -o wide || true
    exit 1
  fi

  sleep "${READY_POLL_SECONDS}"
  waited=$((waited + READY_POLL_SECONDS))
done

kubectl get nodes -o wide

echo "[check] core dns"
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=180s || \
  kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=coredns --timeout=180s

echo "[check] scheduling on workers"
kubectl run probe-nginx --image=nginx:1.27 --restart=Never --port=80 >/dev/null 2>&1 || true
kubectl wait --for=condition=Ready pod/probe-nginx --timeout=180s
kubectl delete pod probe-nginx --ignore-not-found

echo "Cluster validation passed"
