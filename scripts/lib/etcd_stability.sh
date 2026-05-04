#!/usr/bin/env bash

# Helper functions for etcd stability checks during cluster bootstrapping

wait_for_etcd_leader() {
  local kubeconfig_path="$1"
  local timeout_seconds="${2:-120}"
  local poll_seconds="${3:-5}"
  local waited=0
  
  if [[ ! -f "${kubeconfig_path}" ]]; then
    echo "[etcd] kubeconfig not found yet, skipping leader wait" >&2
    return 0
  fi
  
  echo "[etcd] waiting for leader election (timeout: ${timeout_seconds}s)..." >&2
  
  while [[ "${waited}" -lt "${timeout_seconds}" ]]; do
    local status_output
    status_output=$(kubectl --kubeconfig "${kubeconfig_path}" -n kube-system exec etcd-cp1 -- sh -lc \
      'ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/peer.crt \
        --key=/etc/kubernetes/pki/etcd/peer.key \
        endpoint status --write-out=fields' 2>/dev/null || true)
    
    local leader_status
    leader_status=$(echo "$status_output" | grep -oP 'Leader: \K\d+' || echo "0")
    
    if [[ "$leader_status" != "0" && -n "$leader_status" ]]; then
      echo "[etcd] ✓ leader elected (ID: $leader_status)" >&2
      return 0
    fi
    
    sleep "${poll_seconds}"
    waited=$((waited + poll_seconds))
  done
  
  echo "[etcd] ✗ timeout waiting for leader election" >&2
  return 1
}

check_etcd_peer_connectivity() {
  local endpoint_ip="$1"
  local peer_port="${2:-2380}"
  local timeout_seconds="${3:-30}"
  local poll_seconds="${4:-3}"
  local waited=0
  
  echo "[etcd] checking peer connectivity to ${endpoint_ip}:${peer_port}..." >&2
  
  while [[ "${waited}" -lt "${timeout_seconds}" ]]; do
    if timeout 5 bash -c "echo > /dev/tcp/${endpoint_ip}/${peer_port}" 2>/dev/null; then
      echo "[etcd] ✓ peer port ${peer_port} reachable" >&2
      return 0
    fi
    
    sleep "${poll_seconds}"
    waited=$((waited + poll_seconds))
  done
  
  echo "[etcd] ✗ peer port ${peer_port} unreachable after ${timeout_seconds}s" >&2
  return 1
}

count_etcd_learners() {
  local kubeconfig_path="$1"
  
  if [[ ! -f "${kubeconfig_path}" ]]; then
    echo "0"
    return 0
  fi
  
  local learner_count
  learner_count=$(kubectl --kubeconfig "${kubeconfig_path}" -n kube-system exec etcd-cp1 -- sh -lc \
    'ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/peer.crt \
      --key=/etc/kubernetes/pki/etcd/peer.key \
      member list | grep -c "isLearner=true"' 2>/dev/null || echo "0")
  
  echo "$learner_count"
}

