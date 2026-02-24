#!/usr/bin/env bash
set -euo pipefail

cat <<'OUT'
CNI quick comparison for this lab:
- flannel: smallest setup footprint, fastest to bootstrap, fewer network-policy features.
- calico: richer policy and routing controls, moderate resource overhead.
- cilium: eBPF-based advanced dataplane/observability, best with modern kernels and more RAM.

Suggested baseline:
- Start with flannel to validate kubeadm flow.
- Move to calico if you need network policies.
- Test cilium when kernel and resources are confirmed by scripts/probe_host.sh.
OUT
