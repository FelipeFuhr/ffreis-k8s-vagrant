# CP Join Failure Troubleshooting - Quick Reference

## Your Issue

```
cp2: rpc error: code = FailedPrecondition desc = 
etcdserver: can only promote a learner member which is in sync with leader
```

**Meaning:** The etcd learner (cp2's database node) is failing to synchronize with the leader (cp1), so it cannot be promoted to a full cluster member.

---

## Immediate Actions

### 1️⃣ Run Diagnostics
```bash
cd ffreis-k8s-vagrant-lab
bash scripts/diagnose_cp_join_issues.sh
```

### 2️⃣ Clean Stale Learners
```bash
bash scripts/cleanup_stale_learners.sh
```

### 3️⃣ Rebuild
```bash
make down && make up
```

---

## Why This Happens

| Phase | What Happens | Issue |
|-------|--------------|-------|
| 1 | cp1 initializes, becomes etcd leader | ✓ Works |
| 2 | cp2 joins, etcd adds it as learner | ✓ Works |
| 3 | Learner syncs logs from leader | ✗ **FAILS** - Network latency, DNS, or timing |
| 4 | Learner sync timeout | ✗ **ERROR** - Can't promote unsync'd learner |
| 5 | Join fails, retry loop begins | ✗ **LOOP** - 5 retries with 60s backoff |

### Common Culprits

```
❌ Stale learners from previous failed attempts
❌ Network latency/packet loss between cp1 and cp2
❌ DNS resolution not working
❌ Port 2380 (etcd peer) blocked
❌ cp1's etcd not fully ready when cp2 joins
❌ Insufficient wait time between cp1 init and cp2 join
```

---

## Solutions Provided

### ✅ Configuration Changes
- **Location:** `config/cluster.yaml`
- **Changes:** 
  - `join_max_wait_seconds`: 900 → 1200
  - `cp_join_retry_attempts`: 5 → 8
  - `cp_join_retry_max_total_seconds`: 1200 → 2400
- **Effect:** More retries, longer timeouts, gives etcd time to stabilize

### ✅ New Diagnostic Tools
- `scripts/diagnose_cp_join_issues.sh` - Full health check
- `scripts/cleanup_stale_learners.sh` - Remove stuck learners
- `scripts/lib/etcd_stability.sh` - etcd helper functions

### ✅ Documentation
- `QUICK_FIX.md` - Fast action plan (this file!)
- `CONTROL_PLANE_JOIN_FIXES.md` - Detailed troubleshooting
- `../../DIAGNOSTICS_CP_JOIN_FAILURES.md` - Technical deep dive

---

## Testing After Fix

```bash
# All nodes Ready?
kubectl get nodes

# All etcd members synced?
vagrant ssh cp1 -c "sudo bash -c 'ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list'"
# Should show: 3 members, all "started=true", NO "isLearner=true"
```

---

## If Still Broken

### Network Check
```bash
# Can cp1 reach cp2 on port 2380?
vagrant ssh cp1 -c \
  "timeout 5 bash -c 'echo > /dev/tcp/10.30.0.12/2380' && echo OK || echo FAIL"
```

**FAIL?** → Network/firewall issue, run `make clean-libvirt`

### Watch Join in Real-Time
```bash
# Terminal 1 - cp2 kubelet logs
vagrant ssh cp2 -c "sudo journalctl -u kubelet -f"

# Terminal 2 - etcd members list (repeat)
watch -n 2 'vagrant ssh cp1 -c "sudo bash -c \
  \"ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  member list\"" | grep learner'
```

### Full Cleanup
```bash
make down
rm -rf .cluster .vagrant* 
make up
```

---

## Why These Fixes Work

| Fix | Problem It Solves |
|-----|-------------------|
| Longer `join_max_wait_seconds` | cp2 wasn't waiting long enough for cp1 to stabilize |
| More `cp_join_retry_attempts` | Transient network hiccups + silent failures = need more tries |
| Increased backoff sleep | Too-aggressive retries overwhelmed cp1's etcd |
| Longer `cp_stabilize_timeout` | etcd leader election taking longer than expected |
| Cleanup script | Stale learners from previous retries blocking new joins |

All changes are **backward compatible** - they just increase wait times.

---

## Files Modified

✅ `config/cluster.yaml` - Updated timeouts  
✅ `scripts/diagnose_cp_join_issues.sh` - NEW diagnostic tool  
✅ `scripts/cleanup_stale_learners.sh` - NEW cleanup tool  
✅ `scripts/lib/etcd_stability.sh` - NEW etcd helpers  
✅ `CONTROL_PLANE_JOIN_FIXES.md` - Detailed guide  
✅ `QUICK_FIX.md` - This file  

---

**Next Step:** 
1. Run `bash scripts/diagnose_cp_join_issues.sh`
2. Follow the output recommendations
3. `make down && make up`

