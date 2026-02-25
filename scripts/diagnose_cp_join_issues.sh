#!/usr/bin/env bash
set -euo pipefail

# CP Join Diagnostics Script
# Helps identify why control plane nodes fail to join with etcd learner sync errors

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_section() {
  echo -e "${BLUE}=== $1 ===${NC}"
}

log_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

log_error() {
  echo -e "${RED}✗ $1${NC}"
}

# Check if we can run vagrant commands
if ! command -v vagrant >/dev/null 2>&1; then
  log_error "vagrant command not found"
  exit 1
fi

if [[ ! -f .vagrant/machines/cp1/libvirt/id ]] 2>/dev/null; then
  log_error "Vagrant environment not initialized (cp1 not running)"
  exit 1
fi

KUBECONFIG_PATH="${KUBECONFIG_PATH:-./.cluster/admin.conf}"
vagrant status 2>&1 | grep -E '(cp|worker|api-lb)' || true

log_section "2. Network Connectivity Check"

# Test cp1 -> cp2 on etcd peer port
log_warn "Testing cp1 -> cp2 (port 2380)..."
if vagrant ssh cp1 -c "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.12/2380' 2>/dev/null" >/dev/null 2>&1; then
  log_success "cp1 can reach cp2:2380"
else
  log_error "cp1 CANNOT reach cp2:2380 - THIS IS THE PROBLEM"
fi

# Test cp2 -> cp1 on etcd peer port
log_warn "Testing cp2 -> cp1 (port 2380)..."
if vagrant ssh cp2 -c "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.11/2380' 2>/dev/null" >/dev/null 2>&1; then
  log_success "cp2 can reach cp1:2380"
else
  log_error "cp2 CANNOT reach cp1:2380 - THIS IS THE PROBLEM"
fi

# DNS resolution check
log_warn "Testing DNS resolution..."
cp1_dns=$(vagrant ssh cp2 -c "getent hosts cp1" 2>/dev/null | awk '{print $1}' || echo "FAILED")
if [[ "$cp1_dns" == "10.30.0.11" ]]; then
  log_success "cp2 resolves cp1 -> $cp1_dns"
else
  log_error "cp2 cannot resolve cp1 correctly (got: $cp1_dns)"
fi

log_section "3. etcd Member Status (from cp1)"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  log_warn "kubeconfig not found at ${KUBECONFIG_PATH}"
  log_warn "Run 'make kubeconfig' to retrieve it from cp1"
  exit 0
fi

# etcd member list
log_warn "etcd member list:"
member_list=$(vagrant ssh cp1 -c \
  "sudo -u root bash -c 'ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key member list' 2>/dev/null" || echo "")

if [[ -z "$member_list" ]]; then
  log_error "Could not connect to etcd on cp1"
else
  echo "$member_list"
  
  # Count learners
  learner_count=$(echo "$member_list" | grep -c "isLearner=true" || echo "0")
  if [[ "$learner_count" -gt 0 ]]; then
    log_error "Found ${learner_count} stale learner member(s) - these must be removed!"
  fi
fi

log_section "4. etcd Leader/Endpoint Status"

log_warn "etcd endpoint status:"
endpoint_status=$(vagrant ssh cp1 -c \
  "sudo -u root bash -c 'ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key endpoint status --write-out=table' 2>/dev/null" || echo "")

if [[ -z "$endpoint_status" ]]; then
  log_error "Could not get etcd endpoint status"
else
  echo "$endpoint_status"
fi

log_section "5. etcd Alarms"

alarms=$(vagrant ssh cp1 -c \
  "sudo -u root bash -c 'ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key alarm list' 2>/dev/null" || echo "")

if [[ -n "$alarms" && "$alarms" != "memberID:99999999 alarm:none" ]]; then
  log_error "etcd Alarms detected:"
  echo "$alarms"
else
  log_success "No etcd alarms"
fi

log_section "6. Kubernetes Node Status"

if kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes >/dev/null 2>&1; then
  kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide
else
  log_warn "Cannot query node status (cluster may still be bootstrapping)"
fi

log_section "7. Recent Logs from cp2"

if vagrant ssh cp2 -c "systemctl is-active kubelet >/dev/null 2>&1"; then
  log_warn "Last 30 lines of kubelet journal on cp2:"
  vagrant ssh cp2 -c "sudo journalctl -u kubelet -n 30 --no-pager" 2>/dev/null || true
else
  log_warn "kubelet not running on cp2 (expected if join not yet attempted)"
fi

log_section "Summary & Quick Fixes"

echo "If you see network connectivity errors above:"
echo "  1. Check libvirt network configuration:"
echo "     virsh net-list"
echo "     virsh net-info vagrant-libvirt"
echo "  2. Check VM bridge interfaces:"
echo "     vagrant ssh cp1 -c 'ip link | grep -A2 virbr'"
echo ""
echo "If you see stale learners:"
echo "  Run: ./scripts/cleanup_stale_learners.sh"
echo ""
echo "To resolve issues:"
echo "  1. Edit config/cluster.yaml - increase tuning.join_max_wait_seconds"
echo "  2. Rebuild cluster: make destroy && make up"
