# ⚡ Immediate Action Plan - CP Join Failures

**Problem:** cp2 and cp3 failing to join with etcd learner sync errors  
**Root Cause:** etcd synchronization timeout between cp1 (leader) and cp2/cp3 (learners)  
**Time to Fix:** 10-15 minutes

---

## 🎯 Do This Now (In Order)

### 1. Identify the Issue (2 min)
```bash
cd ffreis-k8s-vagrant-lab
bash scripts/diagnose_cp_join_issues.sh 2>&1 | tee /tmp/diag.log
```
**Check output for:**
- ❌ `CANNOT reach cp2:2380` → Network issue
- ❌ `Found N stale learner(s)` → Need cleanup
- ✓ All connectivity OK → Configuration issue (likely)

### 2. Clean Stale Learners (if they exist)
```bash
bash scripts/cleanup_stale_learners.sh
```
Follow the prompts. This removes blocked learner members.

### 3. Rebuild Cluster with Fixed Config
```bash
# Configuration already updated in config/cluster.yaml
# With longer timeouts and more retries

make down   # Destroy current cluster (10 sec)
make up     # Rebuild (3-5 min)
```

**Wait for all nodes to be Ready:**
```bash
kubectl get nodes --watch
# Exit when all show "Ready"
```

---

## ✅ Verification (2 min)

```bash
# All nodes should be Ready
kubectl get nodes
# Expected: 3 cp1 cp2 cp3 nodes, all Ready

# All etcd members should be healthy
vagrant ssh cp1 -c "sudo bash -c 'ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list'"
# Expected: 3 members, all "started=true", NO "isLearner=true"
```

---

## 🔍 If Problem Persists

### Check Network Connectivity
```bash
# From cp1, can reach cp2 on port 2380?
vagrant ssh cp1 -c "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.12/2380' && echo OK || echo FAIL"
```

- If **FAIL** → Network interface issue
  - Check: `virsh net-list`
  - Fix: `make clean-libvirt` (removes and recreates network)

### Monitor Join in Progress
```bash
# Terminal 1: Watch logs from cp2
vagrant ssh cp2 -c "sudo journalctl -u kubelet -f | head -50"

# Terminal 2: Check etcd status (Terminal 1 running cp2 join)
vagrant ssh cp1 -c "watch -n 2 'sudo bash -c \
  \"ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list\"'"
```

Watch for learners appearing and disappearing (normal) or stuck (problem).

### Last Resort: Full Cleanup
```bash
make down
rm -rf .cluster
rm -rf .vagrant*
make up
```

---

## 📊 What Changed

| Setting | Before | After | Why |
|---------|--------|-------|-----|
| join_max_wait_seconds | 900 | 1200 | More time for cp1 etcd to stabilize |
| cp_join_retry_attempts | 5 | 8 | More retries for transient issues |
| cp_join_retry_max_total_seconds | 1200 | 2400 | 40 min timeout total |

These are **conservative, safe defaults** that don't affect normal operations.

---

## 📚 More Help

- Full diagnostics: `DIAGNOSTICS_CP_JOIN_FAILURES.md`
- Detailed guide: `CONTROL_PLANE_JOIN_FIXES.md`
- Scripts created:
  - `scripts/diagnose_cp_join_issues.sh` - Full health check
  - `scripts/cleanup_stale_learners.sh` - Remove stuck learners
  - `scripts/lib/etcd_stability.sh` - etcd helper functions

