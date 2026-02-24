#!/usr/bin/env bash
set -euo pipefail

NODE_NAME="${1:-}"
REQUIRED_CP_COUNT="${2:-}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(pwd)/.cluster/admin.conf}"
TIMEOUT_SECONDS="${KUBE_CP_STABILIZE_TIMEOUT_SECONDS:-${CP_STABILIZE_TIMEOUT_SECONDS:-600}}"
POLL_SECONDS="${KUBE_CP_STABILIZE_POLL_SECONDS:-${CP_STABILIZE_POLL_SECONDS:-5}}"

if [[ -z "${NODE_NAME}" || -z "${REQUIRED_CP_COUNT}" ]]; then
  echo "Usage: $0 <node-name> <required-control-plane-count>" >&2
  exit 1
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "Missing kubeconfig at ${KUBECONFIG_PATH}" >&2
  exit 1
fi

kc() {
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
}

etcd_member_stats() {
  local output
  output="$(
    kc -n kube-system exec etcd-cp1 -- sh -lc '
      ETCDCTL_API=3 etcdctl \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        member list
    ' 2>/dev/null || true
  )"

  awk -F', ' '
    BEGIN { members=0; learners=0 }
    NF > 0 {
      members++
      if ($0 ~ /isLearner=true/ || $NF == "true") learners++
    }
    END { printf "%d %d\n", members, learners }
  ' <<<"${output}"
}

waited=0
echo "[cp-stabilize] waiting for ${NODE_NAME} Ready and etcd stable (cp>=${REQUIRED_CP_COUNT})"
while true; do
  etcd_members=0
  etcd_learners=0
  node_ready="$(
    kc get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
  )"
  ready_cp_count="$(
    kc get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null \
      | awk '$2=="Ready" {count++} END {print count+0}' || true
  )"
  etcd_ready_count="$(
    kc -n kube-system get pods -l component=etcd --no-headers 2>/dev/null \
      | awk '$2 ~ /^1\/1$/ && $3=="Running" {count++} END {print count+0}' || true
  )"
  ready_cp_count="${ready_cp_count:-0}"
  etcd_ready_count="${etcd_ready_count:-0}"

  stats_line="$(etcd_member_stats 2>/dev/null || true)"
  if [[ -n "${stats_line}" ]]; then
    read -r etcd_members etcd_learners <<<"${stats_line}" || true
  fi

  if [[ "${node_ready}" == "True" ]] \
    && [[ "${ready_cp_count}" -ge "${REQUIRED_CP_COUNT}" ]] \
    && [[ "${etcd_ready_count}" -ge "${REQUIRED_CP_COUNT}" ]] \
    && [[ "${etcd_members}" -ge "${REQUIRED_CP_COUNT}" ]] \
    && [[ "${etcd_learners}" -eq 0 ]]; then
    echo "[cp-stabilize] ${NODE_NAME} stable: ready_cp=${ready_cp_count} etcd_ready=${etcd_ready_count} members=${etcd_members} learners=${etcd_learners}"
    exit 0
  fi

  if [[ "${waited}" -ge "${TIMEOUT_SECONDS}" ]]; then
    echo "[cp-stabilize] timeout after ${TIMEOUT_SECONDS}s waiting for ${NODE_NAME}" >&2
    echo "[cp-stabilize] last state: node_ready=${node_ready:-unknown} ready_cp=${ready_cp_count} etcd_ready=${etcd_ready_count} members=${etcd_members} learners=${etcd_learners}" >&2
    kc get nodes -o wide || true
    kc -n kube-system get pods -l component=etcd -o wide || true
    exit 1
  fi

  sleep "${POLL_SECONDS}"
  waited=$((waited + POLL_SECONDS))
done
