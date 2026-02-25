# Vagrant Kubernetes Cluster Lab

Deterministic kubeadm-based Kubernetes lab on Vagrant VMs.

## What this gives you
- Parameterized topology: `n` control planes and `m` workers.
- Bare-metal style guest setup (Ubuntu VMs + kubeadm + containerd).
- Stable API endpoint via dedicated `api-lb` node (HAProxy) for multi-control-plane joins.
- Preflight host probing to adapt to local Ubuntu/chipset/provider limits.
- Feature-by-feature validation after bootstrap.

## Quick start
1. Review and edit `config/cluster.yaml` (primary config source).
2. Probe and verify host compatibility:
   ```bash
   make probe-host
   make doctor
   make preflight
   ```
3. Tune `config/cluster.yaml` (`cluster.control_planes`, `cluster.workers`, `provider.name`, `kubernetes.cni`, `network.api_lb.enabled`).
4. Create cluster:
   ```bash
   make up
   make validate
   ```

`make up` already refreshes `.cluster/admin.conf` for `kubectl`.

## Version pinning
All critical runtime versions are pinned in `config/cluster.yaml`:
- `vagrant.box` and `vagrant.box_version`
- `kubernetes.channel` and `kubernetes.version`
- `kubernetes.pause_image`
- CNI manifest URLs (`kubernetes.cni_manifest_*`)
- `packages.containerd` and `packages.haproxy`

This keeps provisioning output/messages stable across runs and reduces breakage from upstream "latest" changes.

## Package caching
You can reduce repeated `apt` downloads across nodes with an apt proxy (for example `apt-cacher-ng` on host/LAN):
- Set `apt.proxy` in `config/cluster.yaml`, or `KUBE_APT_PROXY` in `config/cluster.env`.
- Example: `http://192.168.121.1:3142`

When unset, behavior remains unchanged (direct upstream downloads).

## Prebaked local box
Best-practice path is Packer image build (with Vagrant fallback):
```bash
make bake-box
```

This creates and registers a local box (`ffreis/k8s-base-ubuntu24` by default).  
`make bake-box` uses Packer when available, else falls back to a Vagrant-only bake.

Explicit options:
```bash
make bake-box-packer
make bake-box-vagrant
```

Host prerequisites for `make bake-box-vagrant` on `libvirt`:
```bash
sudo apt-get update
sudo apt-get install -y libguestfs-tools qemu-utils
```

Then set in `config/cluster.env`:
```bash
KUBE_BOX=ffreis/k8s-base-ubuntu24
KUBE_BOX_VERSION=
```

Optional bake tuning env vars:
- `KUBE_BAKED_BOX_NAME`
- `KUBE_BAKED_CPUS`
- `KUBE_BAKED_MEMORY`
- `KUBE_BAKE_SOURCE_BOX` (default `bento/ubuntu-24.04`)
- `KUBE_BAKE_SOURCE_BOX_VERSION` (Vagrant bake path)

Default behavior:
- `make up` runs `make ensure-box` first.
- If the default baked box (`ffreis/k8s-base-ubuntu24`) is missing, it is auto-built.

## Inputs this project expects from your local system
Run `make probe-host` and use the output to choose:
- `provider.name`: `libvirt` (preferred on Linux) or `virtualbox`.
- `cluster.control_planes` / `cluster.workers` based on available RAM and CPU.
- `kubernetes.cni`: start with `flannel`, then compare with `calico` or `cilium`.

## Alternatives and comparison flow
Use:
```bash
make compare-cni
```

Suggested progression:
1. Validate baseline with `kubernetes.cni: flannel`.
2. Re-test with `kubernetes.cni: calico` for network-policy workflows.
3. Re-test with `kubernetes.cni: cilium` if your kernel/resources are suitable.

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

## Commands
- `make probe-host`: prints host CPU/memory/virtualization/provider signals.
- `make doctor`: verifies required commands/plugins.
- `make compare-cni`: prints CNI tradeoffs.
- `make cp-status`: shows control-plane nodes and etcd leader snapshot.
- `make cp-leader`: prints current etcd leader endpoint view.
- `make cp-wait NODE=cp2 CP=2`: waits for control-plane node and etcd stabilization.
- `make hello-workers`: deploys a hello workload and verifies it runs on workers.
- `make taint-demo`: applies a taint to a worker and demonstrates block/allow with tolerations.
- `make demo-cleanup`: removes demo namespace and demo taints.
- `make ensure-box`: ensures default local baked box exists (auto-builds if missing).
- `make verify-box`: lightweight boot/SSH check for the configured box before full cluster bring-up.
- `make preflight`: topology-aware host resource and route/CIDR conflict checks.
- `make phase-infra`: run infra and control-plane phases only.
- `make phase-workers`: run worker phases only (expects control plane ready).
- `make up`: starts all VMs and provisions Kubernetes.
- `make kubeconfig`: copies kubeconfig from `cp1` to `.cluster/admin.conf`.
- `make validate`: checks node readiness, CoreDNS, and scheduling.
- `make destroy`: tears down VMs and generated state.
- `make destroy-strict`: destroy and assert no residual libvirt domains with project prefix.
- `make collect-failures`: collect VM logs/network snapshots into `.cluster/failures`.
- `make test`: static checks for scripts and `Vagrantfile`.

## Vagrant/libvirt compatibility
Tested baseline for this repo:
- Vagrant `2.4.x` (current tested: `2.4.9`)
- `vagrant-libvirt` plugin `0.12.2`

If you hit recurring libvirt/fog argument warnings or provider oddities:
```bash
vagrant plugin uninstall vagrant-libvirt
vagrant plugin install vagrant-libvirt --plugin-version 0.12.2
```

Note:
- The repeated fog warning `Unrecognized arguments: libvirt_ip_command` is non-fatal in this lab.
- `scripts/vagrant_retry.sh` suppresses that specific known-noise line by default.

## CI
- Fast CI (`ci.yml`, `commit-checks.yml`) runs on GitHub-hosted runners.
- Full Vagrant bring-up CI (`cluster-e2e.yml`) runs on a self-hosted Linux runner with libvirt/KVM.
- E2E CI uses a small HA topology (`KUBE_CP_COUNT=2`, `KUBE_WORKER_COUNT=1`) and checks both control planes are `Ready`.

## Advanced Tuning
Optional `tuning.*` keys in `config/cluster.yaml`:
- `join_max_wait_seconds`: wait budget for join artifact availability.
- `join_poll_seconds`: poll interval for join artifact checks.
- `cp_join_warn_show_limit`: number of repeated etcd learner warnings to print before throttling.
- `cp_join_warn_report_interval_seconds`: interval for throttled warning counter updates.
- `cp_join_warn_report_every`: additional report cadence by suppressed-count threshold.
- `cp_join_retry_attempts`: control-plane join retry-attempt threshold.
- `cp_join_retry_sleep_seconds`: base delay for control-plane join exponential backoff.
- `cp_join_retry_backoff_factor`: multiplier per control-plane join retry.
- `cp_join_retry_max_sleep_seconds`: cap for control-plane join retry sleep.
- `cp_join_retry_max_total_seconds`: total control-plane join retry budget before failing.
- `cp_stabilize_timeout_seconds`: timeout for inter-control-plane stabilization gate.
- `cp_stabilize_poll_seconds`: polling interval for stabilization checks.
- `validate_ready_timeout_seconds`: timeout for all nodes becoming `Ready`.
- `validate_ready_poll_seconds`: poll interval for readiness checks.
- `vagrant_retry_attempts`: lock-retry attempts for wrapped vagrant commands.
- `vagrant_retry_sleep_seconds`: base delay before lock retry backoff starts.
- `vagrant_retry_backoff_factor`: exponential multiplier per retry.
- `vagrant_retry_max_sleep_seconds`: cap for retry sleep duration.
- `vagrant_retry_max_total_seconds`: overall lock-retry time budget before escalation prompt/fail.

Legacy note:
- `config/cluster.env` is still supported as an override layer for compatibility, but `config/cluster.yaml` is canonical.

## Script layout
- `scripts/00_common.sh`: shared Kubernetes node base provisioning.
- `scripts/05_api_lb.sh`: API load balancer (HAProxy) provisioning.
- `scripts/10_init_control_plane.sh`: `cp1` bootstrap and join artifact generation.
- `scripts/20_join_control_plane.sh`: additional control-plane join flow with retries.
- `scripts/30_join_worker.sh`: worker join flow.
- `scripts/lib/logging.sh`: node-aware log helper functions.
- `scripts/lib/retry.sh`: retry and apt/download helpers.
- `scripts/lib/script_init.sh`: shared script lib-directory bootstrap and lib sourcing.
- `scripts/lib/error.sh`: shared error-trap/log helper for consistent script failures.
- `scripts/lib/vagrant_lock.sh`: lock/process cleanup helpers used by Vagrant retry wrapper.
- `scripts/lib/preflight.sh`: shared topology/resource/network preflight checks.
- `scripts/lib/node_contract.sh`: reusable node identity/resource/role checks.
- `scripts/lib/state.sh`: lightweight cluster run-state metadata helpers.
- `scripts/lib/cluster_state.sh`: artifact waiting and join-command parsing helpers.
- `scripts/lib/kubernetes_wait.sh`: Kubernetes/IP readiness wait helpers.
- `scripts/lib/etcd_ops.sh`: etcd member cleanup helpers for control-plane join recovery.
- `scripts/lib/join_retry.sh`: reusable backoff retry loop for join workflows.
- `scripts/vagrant_retry.sh`: lock-aware Vagrant command wrapper.
- `scripts/cleanup_all.sh`: canonical cleanup entrypoint for cluster and bake state.
- `scripts/check_cp1_ready.sh`: validates cp1 API/node/artifacts readiness contract.
- `scripts/run_up_flow.sh`: phase-based orchestration (preflight, infra, cp bootstrap, worker parallelism, kubeconfig).
- `scripts/collect_failures.sh`: centralized failure bundle collection.
- `scripts/libvirt_cleanup.sh`: orphan domain/volume cleanup with optional sudo prompt.
