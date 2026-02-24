#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKER_DIR="${ROOT_DIR}/packer"
BOX_DIR="${ROOT_DIR}/.bake/boxes"

KUBE_PROVIDER="${KUBE_PROVIDER:-libvirt}"
KUBE_BOX="${KUBE_BOX:-bento/ubuntu-24.04}"
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CHANNEL="${KUBE_CHANNEL:-v1.30}"
KUBE_CONTAINERD_VERSION="${KUBE_CONTAINERD_VERSION:-1.7.28-0ubuntu1~24.04.2}"
KUBE_PAUSE_IMAGE="${KUBE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"
KUBE_BAKED_BOX_NAME="${KUBE_BAKED_BOX_NAME:-ffreis/k8s-base-ubuntu24}"

BOX_FILE="${BOX_DIR}/${KUBE_BAKED_BOX_NAME//\//-}.box"

if ! command -v packer >/dev/null 2>&1; then
  echo "packer not found in PATH" >&2
  exit 1
fi

mkdir -p "${BOX_DIR}"

pushd "${PACKER_DIR}" >/dev/null
packer init k8s-base.pkr.hcl
packer build \
  -var "provider=${KUBE_PROVIDER}" \
  -var "source_box=${KUBE_BOX}" \
  -var "box_output=${BOX_FILE}" \
  -var "kube_version=${KUBE_VERSION}" \
  -var "kube_channel=${KUBE_CHANNEL}" \
  -var "containerd_version=${KUBE_CONTAINERD_VERSION}" \
  -var "pause_image=${KUBE_PAUSE_IMAGE}" \
  -var "apt_proxy=${KUBE_APT_PROXY}" \
  k8s-base.pkr.hcl
popd >/dev/null

vagrant box add --force "${KUBE_BAKED_BOX_NAME}" "${BOX_FILE}"

cat <<EOF
Packer-baked box created and added:
  box name: ${KUBE_BAKED_BOX_NAME}
  box file: ${BOX_FILE}

To use it for this lab, set:
  KUBE_BOX=${KUBE_BAKED_BOX_NAME}
  KUBE_BOX_VERSION=
in config/cluster.env (or export them in shell).
EOF
