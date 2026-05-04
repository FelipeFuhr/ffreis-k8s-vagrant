#!/usr/bin/env bash
set -euo pipefail

# Cleanup stale etcd learner members that block new control plane joins
# This is useful when cp2/cp3 failed to join and left stale learner members in etcd

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-./.cluster/admin.conf}"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "ERROR: Missing kubeconfig at ${KUBECONFIG_PATH}" >&2
  echo "Run 'make kubeconfig' first to retrieve it from cp1" >&2
  exit 1
fi

echo "[cleanup] Querying etcd learner members..."

learner_list=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system exec etcd-cp1 -- sh -lc \
  'ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/peer.crt \
    --key=/etc/kubernetes/pki/etcd/peer.key \
    member list' 2>/dev/null || true)

if [[ -z "$learner_list" ]]; then
  echo "ERROR: Could not connect to etcd on cp1" >&2
  exit 1
fi

echo "$learner_list"
echo ""

# Extract learner members
learners=$(echo "$learner_list" | grep "isLearner=true" || true)

if [[ -z "$learners" ]]; then
  echo "[cleanup] ✓ No stale learners found"
  exit 0
fi

echo "[cleanup] Found stale learner members:"
echo "$learners"
echo ""

# Ask for confirmation
read -p "Remove these learner members? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "[cleanup] Cancelled"
  exit 0
fi

# Remove each learner
while IFS= read -r line; do
  member_id=$(echo "$line" | awk -F', ' '{print $1}')
  member_name=$(echo "$line" | awk -F', ' '{print $3}' | tr -d ' ')
  
  echo "[cleanup] Removing learner member: $member_name (ID: $member_id)"
  
  kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system exec etcd-cp1 -- sh -lc \
    "ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/peer.crt \
      --key=/etc/kubernetes/pki/etcd/peer.key \
      member remove ${member_id}" >/dev/null 2>&1
  
  if [[ $? -eq 0 ]]; then
    echo "[cleanup] ✓ Removed $member_name"
  else
    echo "[cleanup] ✗ Failed to remove $member_name" >&2
  fi
done <<<"$learners"

echo ""
echo "[cleanup] Verifying cleanup..."
verify=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system exec etcd-cp1 -- sh -lc \
  'ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/peer.crt \
    --key=/etc/kubernetes/pki/etcd/peer.key \
    member list' 2>/dev/null || true)

remaining_learners=$(echo "$verify" | grep -c "isLearner=true" || echo "0")

if [[ "$remaining_learners" -eq 0 ]]; then
  echo "[cleanup] ✓ All stale learners removed"
  echo ""
  echo "Current etcd members:"
  echo "$verify"
else
  echo "[cleanup] ✗ Warning: $remaining_learners learner(s) still remain" >&2
  exit 1
fi

