#!/usr/bin/env bash
set -euo pipefail

ruby -c Vagrantfile >/dev/null

for script in scripts/*.sh; do
  bash -n "${script}"
done

if compgen -G "examples/*.sh" >/dev/null; then
  for script in examples/*.sh; do
    bash -n "${script}"
  done
fi

mkdir -p .cluster
tmp_env="$(mktemp)"
cp config/cluster.env.example "${tmp_env}"

# Ensure expected keys are present in default config for deterministic bootstrapping.
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
  if ! grep -q "^${key}=" "${tmp_env}"; then
    echo "Missing required key in cluster.env.example: ${key}"
    exit 1
  fi
done

rm -f "${tmp_env}"

echo "Static checks passed"
