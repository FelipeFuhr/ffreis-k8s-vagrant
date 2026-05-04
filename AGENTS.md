# Agent Context

**This repo:** `ffreis-k8s-vagrant-lab` — kubeadm-based Kubernetes cluster (advanced
version of `ffreis-k8s-vagrant`). Uses YAML config instead of env vars, supports
Packer box baking, and has fine-grained tuning knobs.

## Non-obvious facts

- **`config/cluster.yaml` is the canonical config.** It pins all versions: Vagrant box,
  Kubernetes channel/version, pause image, CNI manifests, package list. Do not rely on
  "latest" for any of these.

- **`config/cluster.env` is a backward-compat override layer.** For new tuning, prefer
  `cluster.yaml`. Only use `cluster.env` for local overrides that should not be
  committed.

- **Packer box baking (`make bake-box`)** pre-installs packages into a reusable Vagrant
  box. Dramatically speeds up repeated cluster bring-ups at the cost of a one-time
  bake step. Use this for frequent teardown/recreate workflows.

- **Advanced timing controls in `cluster.yaml`:** join wait budgets, retry backoff,
  stability timeouts, logging cadences. Do not hardcode these in scripts — they belong
  in config.

- **`make preflight` checks for route/CIDR conflicts** before bring-up. Always run it
  if you change the cluster CIDR or add host routes.

- **`make destroy-strict`** asserts no orphan libvirt domains remain after destroy.
  Use this in CI or automated teardown to catch resource leaks.

- **Same external etcd + HA API LB architecture** as `ffreis-k8s-vagrant`. Same
  bring-up order constraints apply.

## Structure

```
config/cluster.yaml     ← canonical config (all version pins)
config/cluster.env      ← override layer (gitignored)
Makefile
.cluster/               ← state
scripts/                ← provisioning scripts (same phase structure as k8s-vagrant)
```

## Build/run

```bash
# edit config/cluster.yaml
make preflight
make bake-box          # optional; fast subsequent brings-up
make up                # or make phase-infra + make phase-workers
make validate
make destroy-strict
```

## Relation to other local-dev repos

More configurable but heavier than `ffreis-k8s-vagrant`. Use this when you need
version-pinned reproducibility or Packer baking. Use `ffreis-k3s-vagrant` for
the lightest, fastest cluster.

## Keeping this file current

- **If you discover a fact not reflected here:** add it before finishing your task.
- **If something here is wrong or outdated:** correct it in the same commit as the code change.
- **If you rename a file, command, or concept referenced here:** update the reference.
