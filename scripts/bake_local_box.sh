#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAKE_ROOT="${ROOT_DIR}/.bake/basebox"
BOX_DIR="${ROOT_DIR}/.bake/boxes"

KUBE_PROVIDER="${KUBE_PROVIDER:-libvirt}"
KUBE_BAKE_SOURCE_BOX="${KUBE_BAKE_SOURCE_BOX:-bento/ubuntu-24.04}"
KUBE_BAKE_SOURCE_BOX_VERSION="${KUBE_BAKE_SOURCE_BOX_VERSION:-202508.03.0}"
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CHANNEL="${KUBE_CHANNEL:-v1.30}"
KUBE_CONTAINERD_VERSION="${KUBE_CONTAINERD_VERSION:-}"
KUBE_PAUSE_IMAGE="${KUBE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"
KUBE_BAKED_BOX_NAME="${KUBE_BAKED_BOX_NAME:-ffreis/k8s-base-ubuntu24}"
KUBE_BAKED_CPUS="${KUBE_BAKED_CPUS:-2}"
KUBE_BAKED_MEMORY="${KUBE_BAKED_MEMORY:-2048}"
BAKE_MACHINE_NAME="${KUBE_BAKE_MACHINE_NAME:-box-bake}"
KUBE_BAKE_USE_VAGRANT_PACKAGE="${KUBE_BAKE_USE_VAGRANT_PACKAGE:-auto}"
KUBE_BAKE_MIN_FREE_GB="${KUBE_BAKE_MIN_FREE_GB:-12}"

BOX_FILE="${BOX_DIR}/${KUBE_BAKED_BOX_NAME//\//-}.box"
VAGRANT_RETRY_SCRIPT="${ROOT_DIR}/scripts/vagrant_retry.sh"

# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/bake/common.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/bake/package_manual.sh"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/bake/package_vagrant.sh"

bake_require_host_cmd "vagrant" "https://developer.hashicorp.com/vagrant/install"
if [[ "${KUBE_PROVIDER}" == "libvirt" ]]; then
  bake_require_host_cmd "virt-sysprep" "sudo apt-get update && sudo apt-get install -y libguestfs-tools"
  bake_require_host_cmd "virt-sparsify" "sudo apt-get update && sudo apt-get install -y libguestfs-tools"
  bake_require_host_cmd "qemu-img" "sudo apt-get update && sudo apt-get install -y qemu-utils"
fi

"${ROOT_DIR}/scripts/cleanup_all.sh" bake >/dev/null 2>&1 || true
mkdir -p "${BAKE_ROOT}" "${BOX_DIR}"
rm -rf "${BAKE_ROOT:?}"/*

bake_write_vagrantfile

pushd "${BAKE_ROOT}" >/dev/null
bake_run_vagrant up "${BAKE_MACHINE_NAME}" --provider "${KUBE_PROVIDER}"
bake_restore_vagrant_insecure_key

if [[ "${KUBE_PROVIDER}" == "libvirt" && "${KUBE_BAKE_USE_VAGRANT_PACKAGE}" != "true" ]]; then
  echo "[box] using manual libvirt packaging path (skip virt-sysprep/virt-sparsify)"
  bake_run_vagrant halt "${BAKE_MACHINE_NAME}" -f || true
  bake_package_box_without_libguestfs "${BAKE_ROOT}" "${BOX_FILE}"
else
  if ! bake_package_box_with_vagrant "${BOX_FILE}"; then
    if [[ "${KUBE_PROVIDER}" == "libvirt" ]]; then
      echo "[box] vagrant package failed or produced invalid box; using manual libvirt packaging fallback"
      bake_package_box_without_libguestfs "${BAKE_ROOT}" "${BOX_FILE}"
    else
      popd >/dev/null
      exit 1
    fi
  fi
fi

bake_run_vagrant destroy -f "${BAKE_MACHINE_NAME}"
popd >/dev/null

if ! bake_validate_box_file "${BOX_FILE}"; then
  echo "[box] packaged box is corrupt or incomplete: ${BOX_FILE}" >&2
  exit 1
fi

bake_run_vagrant box add --force "${KUBE_BAKED_BOX_NAME}" "${BOX_FILE}"

cat <<__OUT__
Baked local box created and added:
  box name: ${KUBE_BAKED_BOX_NAME}
  box file: ${BOX_FILE}

To use it for this lab, set:
  KUBE_BOX=${KUBE_BAKED_BOX_NAME}
  KUBE_BOX_VERSION=
in config/cluster.env (or export them in shell).
__OUT__
