# Vagrant Kubernetes Cluster Lab

Deterministic kubeadm-based Kubernetes lab on Vagrant VMs.

## What this gives you
- Parameterized topology: `n` control planes and `m` workers.
- Dedicated external etcd topology with configurable replicas (`etcd1..etcdN`, default `3`).
- Bare-metal style guest setup (Ubuntu VMs + kubeadm + containerd).
- Stable API endpoint via dedicated `api-lb` node (HAProxy) for multi-control-plane joins.
- Preflight host probing to adapt to local Ubuntu/chipset/provider limits.
- Feature-by-feature validation after bootstrap.

## Quick start
1. Copy defaults:
   ```bash
   cp config/cluster.env.example config/cluster.env
   ```
2. Probe and verify host compatibility:
   ```bash
   make probe-host
   make doctor
   ```
3. Tune `config/cluster.env` (`KUBE_CP_COUNT`, `KUBE_WORKER_COUNT`, `KUBE_PROVIDER`, `KUBE_CNI`, `KUBE_API_LB_ENABLED`, `KUBE_ETCD_COUNT`).
   You can also override any variable per command, for example: `make up KUBE_CP_COUNT=2 KUBE_WORKER_COUNT=0`.
   For multi-control-plane join behavior, tune `CP_JOIN_*` and `ETCD_WARN_*` variables.
   For generic progress logging cadence across waiting loops, tune `WAIT_REPORT_INTERVAL_SECONDS`.
4. Create cluster:
   ```bash
   make up
   make kubeconfig
   make validate
   ```

## Inputs this project expects from your local system
Run `make probe-host` and use the output to choose:
- `KUBE_PROVIDER`: `libvirt` (preferred on Linux) or `virtualbox`.
- `KUBE_CP_COUNT` / `KUBE_WORKER_COUNT` based on available RAM and CPU.
- `KUBE_ETCD_COUNT`: dedicated external etcd replicas (`>=3`, typically `3`).
- `KUBE_ETCD_VERSION`: external etcd version (default `3.5.15`).
- `KUBE_CNI`: start with `flannel`, then compare with `calico` or `cilium`.

## External etcd
This lab always runs dedicated etcd nodes. Default is 3 replicas:
```bash
make destroy
make up KUBE_ETCD_COUNT=3
```
Vagrant brings up `etcd1..etcdN` before `cp1`, and `cp1` bootstraps kubeadm against those external etcd endpoints.
During `make up`, the flow is health-gated in order: external etcd healthy -> cp1 ready -> each additional control-plane join (with etcd/API readiness checks between joins).

## Alternatives and comparison flow
Use:
```bash
make compare-cni
```

Suggested progression:
1. Validate baseline with `KUBE_CNI=flannel`.
2. Re-test with `KUBE_CNI=calico` for network-policy workflows.
3. Re-test with `KUBE_CNI=cilium` if your kernel/resources are suitable.

For each variation:
```bash
make destroy
make up
make kubeconfig
make validate
```

## Troubleshooting
If `kubeadm init` fails on `cp1` with API connection errors (`connect: connection refused`):
1. Re-run bootstrap after cleanup:
   ```bash
   make destroy
   make up
   ```
2. Inspect collected kubelet logs from the failed attempt on the host:
   - `.cluster/cp1-kubelet-init.log`
   - `.cluster/cp1-kubelet-error.log`
   - `.cluster/failed`

## Important limitation
This lab now uses a dedicated `api-lb` VM as the kubeadm `control-plane-endpoint` (default: `10.30.0.5:6443`).
It improves control-plane resilience versus anchoring API traffic to `cp1`, but it is still not full production HA because `api-lb` is a single node. For production-style HA, run at least two API LBs with a floating VIP (for example keepalived) or an external managed load balancer.
When `KUBE_CP_COUNT=1`, `api-lb` is skipped automatically to reduce CPU/RAM usage.

## Commands
- `make probe-host`: prints host CPU/memory/virtualization/provider signals.
- `make doctor`: verifies required commands/plugins.
- `make compare-cni`: prints CNI tradeoffs.
- `make up`: starts all VMs and provisions Kubernetes.
- `make kubeconfig`: copies kubeconfig from `cp1` to `.cluster/admin.conf`.
- `make validate`: checks node readiness, CoreDNS, and scheduling.
- `make destroy`: tears down VMs and generated state.
- `make test`: static checks for scripts and `Vagrantfile`.

## Examples
Control-plane connectivity check (from host):
```bash
./examples/check_control_plane_connectivity.sh
make cp-connectivity
```
It validates `cp1..cpN` peer reachability with:
- ICMP ping between control-plane nodes.
- TCP connectivity on `6443` between control-plane nodes.

Example script self-test (verifies success/failure exit paths):
```bash
make test-examples
```

Control-plane failover test (takes one control-plane node down and back up):
```bash
./examples/test_control_plane_failover.sh
make cp-failover
```
Optional: pass a specific target node (for example `cp2`):
```bash
./examples/test_control_plane_failover.sh cp2
```

Taints/tolerations worker sanity test (temporary taints + hello-world pods + cleanup):
```bash
./examples/sanity_taints_tolerations.sh
make sanity-taints
```
