#!/usr/bin/env bash
set -euo pipefail

ruby -c Vagrantfile >/dev/null

for script in $(find scripts -type f -name '*.sh' | sort); do
  bash -n "${script}"
done

mkdir -p .cluster
tmp_mk="$(mktemp)"
./scripts/config/render_env_from_yaml.sh config/cluster.yaml "${tmp_mk}"

# Ensure expected keys are rendered from YAML for deterministic bootstrapping.
required_keys=(
  KUBE_CP_COUNT
  KUBE_WORKER_COUNT
  KUBE_PROVIDER
  KUBE_VERSION
  KUBE_CNI
  KUBE_API_LB_ENABLED
  KUBE_API_LB_IP
)
for key in "${required_keys[@]}"; do
  if ! grep -q "^${key} :=" "${tmp_mk}"; then
    echo "Missing required rendered key from cluster.yaml: ${key}"
    exit 1
  fi
done

rm -f "${tmp_mk}"

./tests/test_vagrant_lock_lib.sh

echo "Static checks passed"
