# Control Plane Join Failure Resolution Guide

## Problem Summary

Your CP nodes (cp2, cp3) are failing to join the cluster with this error:
```
rpc error: code = FailedPrecondition desc = etcdserver: can only promote a learner member which is in sync with leader
```

This means **etcd learner synchronization is failing** between the leader (cp1) and joiners (cp2/cp3).

---

## Quick Start: 3-Step Fix

### Step 1: Run Diagnostics
```bash
cd ffreis-k8s-vagrant-lab
bash scripts/diagnose_cp_join_issues.sh
```

This will show you:
- Network connectivity between nodes
- etcd member status
- Current cluster state
- Recommendations

### Step 2: If stale learners are present
```bash
bash scripts/cleanup_stale_learners.sh
```

This removes stuck learner members that are preventing new joins.

### Step 3: Rebuild with improved configuration
```bash
# Configuration has been updated with longer timeouts
make down
make up
```

---

## What Was Fixed

### Configuration Changes (in `config/cluster.yaml`)

| Parameter | Old | New | Reason |
|-----------|-----|-----|--------|
| `join_max_wait_seconds` | 900 | 1200 | Give cp1 more time to stabilize before cp2 joins |
| `cp_join_retry_attempts` | 5 | 8 | More retry attempts for transient network issues |
| `cp_join_retry_max_sleep_seconds` | 90 | 120 | Allow longer backoff between retries |
| `cp_join_retry_max_total_seconds` | 1200 | 2400 | Total timeout of 40 minutes for multi-CP joins |
| `cp_stabilize_timeout_seconds` | 600 | 900 | More time for etcd rebalancing after cp1 init |

### New Diagnostic Scripts

- **`scripts/diagnose_cp_join_issues.sh`** - Full cluster connectivity and etcd health check
- **`scripts/cleanup_stale_learners.sh`** - Remove stuck learner members blocking joins
- **`scripts/lib/etcd_stability.sh`** - Helper functions for etcd health checks

---

## Understanding the Root Cause

The error occurs because:

1. **cp1** initializes and becomes etcd leader ✓
2. **cp2** starts joining, etcd adds it as a learner
3. **Learner sync fails** because:
   - Network latency or packet loss
   - DNS resolution issues
   - etcd leader not fully ready
   - Previous failed join left stale learner in bad state
4. Join fails with "can only promote a learner in sync" ✗
5. Retry loop: reset node → sleep 60s → retry (up to 5 times)

---

## Detailed Diagnostics Guide

Run these commands to investigate:

### 1. Check Network Between CPs

```bash
# From host machine
cd ffreis-k8s-vagrant-lab

# Can cp1 reach cp2's etcd peer port?
vagrant ssh cp1 -c "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.12/2380' && echo OK || echo FAIL"

# Can cp2 reach cp1's etcd peer port?
vagrant ssh cp2 -c "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.11/2380' && echo OK || echo FAIL"
```

If either shows **FAIL**, you have a network connectivity issue:
- Check `virsh net-list` (libvirt network)
- Check VM interfaces: `vagrant ssh cp1 -c "ip route"`
- Check firewall: `vagrant ssh cp1 -c "sudo iptables -L"`

### 2. Check etcd Member Status

```bash
# Get superuser shell on cp1
vagrant ssh cp1 -c "sudo -i"

# List all etcd members
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list

# Output example:
#  8927e4c2c81df03, started, cp1, https://10.30.0.11:2380, https://127.0.0.1:2379, false
#  d5f3b0a1b5c01f2, started, cp2, https://10.30.0.12:2380, https://127.0.0.1:2378, true
```

If you see **isLearner=true** for cp2, it's a stale learner. Remove it:
```bash
bash scripts/cleanup_stale_learners.sh
```

### 3. Check etcd Leader Status

```bash
vagrant ssh cp1 -c "sudo bash -c 'ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  endpoint status --write-out=table'"
```

Expected output shows:
- Leader: **true** (for cp1)
- Raft Index: Increasing number
- Health: **true**

### 4. Monitor Join Progress

**Terminal 1** - Monitor cp2 kubelet logs:
```bash
vagrant ssh cp2 -c "sudo journalctl -u kubelet -f"
```

**Terminal 2** - Trigger join (if not already running):
```bash
vagrant ssh cp2 -c "sudo /vagrant/scripts/20_join_control_plane.sh"
```

Watch for:
- `etcd learner warnings suppressed: XXX` - etcd sync not working
- Network timeouts
- Successful join completion

---

## Advanced Troubleshooting

### Issue: "too many learner members in cluster"

```bash
# Multiple previous join failures left learner members
bash scripts/cleanup_stale_learners.sh
```

### Issue: Learner never syncs even after cleanup

The learner sync can fail if:

1. **etcd process on cp1 is unhealthy:**
   ```bash
   vagrant ssh cp1 -c "sudo systemctl status etcd.service" || \
   vagrant ssh cp1 -c "sudo systemctl status kubelet | grep etcd"
   ```

2. **etcd database is corrupted:**
   ```bash
   vagrant ssh cp1 -c "sudo -i"
   systemctl stop kubelet containerd
   rm -rf /var/lib/etcd/*
   systemctl start kubelet containerd
   ```

3. **Network partition between CPs:**
   - Check libvirt network: `virsh net-dumpxml vagrant-libvirt`
   - Check bridge status: `brctl show || sudo ip link show`

### Issue: Join succeeds but node stays NotReady

```bash
# Check node readiness
kubectl get nodes -o wide

# Check CNI plugin
kubectl get pods -n kube-system -o wide | grep flannel

# Check kubelet logs
vagrant ssh cp2 -c "sudo journalctl -u kubelet -n 100"
```

---

## Performance Tuning For Your Setup

If 3 CPs still struggle, try:

### For 3+ Control Planes

**Edit `config/cluster.yaml`:**
```yaml
resources:
  control_plane:
    cpus: 4      # Increased from 2
    memory: 6144 # Increased from 4096
```

**Edit `config/cluster.yaml`:**
```yaml
tuning:
  cp_join_retry_sleep_seconds: 20  # More time between retries
  cp_join_retry_max_sleep_seconds: 180  # Longer backoff
```

### Stagger CP Startup

If `make up` brings up all CPs simultaneously:

1. Modify Vagrantfile to start cp1 first
2. Wait for cp1 to be Ready
3. Start cp2
4. Wait for stable
5. Start cp3

---

## Verification

Once cluster is stable with 3 CPs:

```bash
# Check all CPs are Ready
kubectl get nodes

# Check all etcd members are healthy
vagrant ssh cp1 -c "sudo bash -c 'ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list'"

# All members should show "started=true" and no learners
```

---

## References

- Original diagnostic details: [DIAGNOSTICS_CP_JOIN_FAILURES.md](../../DIAGNOSTICS_CP_JOIN_FAILURES.md)
- etcd clustering: https://etcd.io/docs/v3.5/op-guide/clustering/
- kubeadm HA: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability-etcd/

