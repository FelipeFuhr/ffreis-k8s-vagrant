# Agent Context

**This repo:** `ffreis-k8s-vagrant` — deterministic kubeadm-based Kubernetes cluster
on Vagrant VMs. Full-featured production-like setup with external etcd, multi-control-
plane HA, and configurable CNI.

## Non-obvious facts

- **External etcd topology — always.** Do not regress to embedded etcd. External etcd
  is required for independent control plane scaling.

- **API load balancer at `10.30.0.5:6443`** (HAProxy) fronts multiple control planes.
  `make kubeconfig-ha` generates a kubeconfig pointing to the LB, not a single CP.
  Use the HA kubeconfig for production-like testing.

- **Bring-up order is enforced with readiness gates:**
  etcd healthy → cp1 ready → cp2+ join sequentially. Parallel CP joins cause etcd
  split-brain. Never run `make up-cps` before `make up-cp1` is fully complete.

- **Preflight host probing** via `make probe-host` / `make doctor` adapts to local
  CPU/memory/virtualization limits. Run this before first bring-up.

- **CNI options:** calico (default), flannel (lighter), cilium (eBPF). Change via
  `config/cluster.env`. Calico requires more CPU than flannel; use flannel for minimal VMs.

- **Box version is pinned** (`bento/ubuntu-24.04` with specific version). Never
  change to `latest` — uncontrolled provisioning changes will cause silent breakage.

- **Failure logs:** `.cluster/cp1-kubelet-init.log`, `.cluster/cp1-kubelet-error.log`,
  `.cluster/failed`. Check these first when bring-up fails.

## Structure

```
config/cluster.env      ← topology (gitignored; copy from .example)
Makefile
.cluster/               ← kubeconfig, logs, state
scripts/                ← provisioning phases (00_common → 30_join_worker)
examples/               ← failover tests, etcd checks
```

## Build/run

```bash
cp config/cluster.env.example config/cluster.env
make probe-host && make doctor
make up                    # or phase-by-phase
make validate
make kubeconfig-ha         # HA endpoint kubeconfig
make cp-failover           # test control plane failover
make destroy
```

## Keeping this file current

- **If you discover a fact not reflected here:** add it before finishing your task.
- **If something here is wrong or outdated:** correct it in the same commit as the code change.
- **If you rename a file, command, or concept referenced here:** update the reference.
