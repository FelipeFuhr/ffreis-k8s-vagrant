#!/usr/bin/env bash
set -euo pipefail

cat <<'OUT'
CNI quick comparison for this lab:
- flannel: smallest setup footprint, fastest to bootstrap, fewer network-policy features.
- calico: richer policy and routing controls, moderate resource overhead.
- cilium: eBPF-based advanced dataplane/observability, best with modern kernels and more RAM.

Suggested baseline:
- Start with calico for policy-ready defaults in this lab.
- Use flannel if you want the lightest/fastest bootstrap path.
- Test cilium when kernel and resources are confirmed by scripts/probe_host.sh.
OUT
