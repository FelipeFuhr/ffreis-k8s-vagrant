#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAKE_ROOT="${ROOT_DIR}/.bake/basebox"
BOX_DIR="${ROOT_DIR}/.bake/boxes"

KUBE_PROVIDER="${KUBE_PROVIDER:-libvirt}"
KUBE_BOX="${KUBE_BOX:-bento/ubuntu-24.04}"
KUBE_BOX_VERSION="${KUBE_BOX_VERSION:-}"
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CHANNEL="${KUBE_CHANNEL:-v1.30}"
KUBE_CONTAINERD_VERSION="${KUBE_CONTAINERD_VERSION:-}"
KUBE_PAUSE_IMAGE="${KUBE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"
KUBE_BAKED_BOX_NAME="${KUBE_BAKED_BOX_NAME:-ffreis/k8s-base-ubuntu24}"
KUBE_BAKED_CPUS="${KUBE_BAKED_CPUS:-2}"
KUBE_BAKED_MEMORY="${KUBE_BAKED_MEMORY:-2048}"

BOX_FILE="${BOX_DIR}/${KUBE_BAKED_BOX_NAME//\//-}.box"

mkdir -p "${BAKE_ROOT}" "${BOX_DIR}"
rm -rf "${BAKE_ROOT:?}"/*

cat >"${BAKE_ROOT}/Vagrantfile" <<RUBY
Vagrant.configure("2") do |config|
  config.vm.box = "${KUBE_BOX}"
  config.vm.box_version = "${KUBE_BOX_VERSION}" unless "${KUBE_BOX_VERSION}".empty?
  config.vm.hostname = "box-bake"
  config.vm.synced_folder "${ROOT_DIR}", "/vagrant", type: "rsync"

  config.vm.provider "${KUBE_PROVIDER}" do |p|
    p.cpus = ${KUBE_BAKED_CPUS}
    p.memory = ${KUBE_BAKED_MEMORY}
  end

  config.vm.provision "shell", path: "/vagrant/scripts/00_common.sh", env: {
    "NODE_ROLE" => "worker",
    "NODE_NAME" => "box-bake",
    "KUBE_VERSION" => "${KUBE_VERSION}",
    "KUBE_CHANNEL" => "${KUBE_CHANNEL}",
    "KUBE_CONTAINERD_VERSION" => "${KUBE_CONTAINERD_VERSION}",
    "KUBE_PAUSE_IMAGE" => "${KUBE_PAUSE_IMAGE}",
    "KUBE_APT_PROXY" => "${KUBE_APT_PROXY}"
  }
end
RUBY

pushd "${BAKE_ROOT}" >/dev/null
vagrant up --provider "${KUBE_PROVIDER}"
vagrant package --output "${BOX_FILE}"
vagrant destroy -f
popd >/dev/null

vagrant box add --force "${KUBE_BAKED_BOX_NAME}" "${BOX_FILE}"

cat <<EOF
Baked local box created and added:
  box name: ${KUBE_BAKED_BOX_NAME}
  box file: ${BOX_FILE}

To use it for this lab, set:
  KUBE_BOX=${KUBE_BAKED_BOX_NAME}
  KUBE_BOX_VERSION=
in config/cluster.env (or export them in shell).
EOF
