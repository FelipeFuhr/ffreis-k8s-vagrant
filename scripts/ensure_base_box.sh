#!/usr/bin/env bash
set -euo pipefail

KUBE_BOX="${KUBE_BOX:-ffreis/k8s-base-ubuntu24}"
KUBE_BOX_VERSION="${KUBE_BOX_VERSION:-}"
KUBE_DEFAULT_BAKED_BOX="${KUBE_DEFAULT_BAKED_BOX:-ffreis/k8s-base-ubuntu24}"

if ! command -v vagrant >/dev/null 2>&1; then
  echo "vagrant not found in PATH" >&2
  exit 1
fi

box_exists=0
if vagrant box list 2>/dev/null | awk '{print $1}' | grep -qx "${KUBE_BOX}"; then
  box_exists=1
fi

if [[ "${box_exists}" -eq 1 ]]; then
  echo "[box] using local box '${KUBE_BOX}'"
  exit 0
fi

if [[ "${KUBE_BOX}" != "${KUBE_DEFAULT_BAKED_BOX}" ]]; then
  echo "[box] requested box '${KUBE_BOX}' not found locally." >&2
  echo "[box] run 'vagrant box add ${KUBE_BOX} ...' or change KUBE_BOX to ${KUBE_DEFAULT_BAKED_BOX}." >&2
  exit 1
fi

echo "[box] default baked box '${KUBE_BOX}' not found; building now..."
if command -v packer >/dev/null 2>&1; then
  ./scripts/bake_packer_box.sh
else
  echo "[box] packer not found, using Vagrant-only bake fallback"
  ./scripts/bake_local_box.sh
fi

if ! vagrant box list 2>/dev/null | awk '{print $1}' | grep -qx "${KUBE_BOX}"; then
  echo "[box] failed to create local box '${KUBE_BOX}'" >&2
  exit 1
fi

echo "[box] ready: '${KUBE_BOX}'"
