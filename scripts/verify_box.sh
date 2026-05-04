#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_ROOT="${ROOT_DIR}/.verify-box"
VAGRANT_RUN="${ROOT_DIR}/scripts/vagrant_retry.sh"

KUBE_PROVIDER="${KUBE_PROVIDER:-libvirt}"
KUBE_BOX="${KUBE_BOX:-ffreis/k8s-base-ubuntu24}"
KUBE_BOX_VERSION="${KUBE_BOX_VERSION:-}"

mkdir -p "${VERIFY_ROOT}"
rm -rf "${VERIFY_ROOT:?}"/*

cat >"${VERIFY_ROOT}/Vagrantfile" <<__VAGRANT__
Vagrant.configure("2") do |config|
  config.ssh.insert_key = false
  config.vm.box = "${KUBE_BOX}"
  config.vm.box_version = "${KUBE_BOX_VERSION}" unless "${KUBE_BOX_VERSION}".empty?
  config.vm.define "verify-box", primary: true do |m|
    m.vm.hostname = "verify-box"
    m.vm.provider "${KUBE_PROVIDER}" do |p|
      p.cpus = 1
      p.memory = 1024
    end
  end
end
__VAGRANT__

pushd "${VERIFY_ROOT}" >/dev/null
"${VAGRANT_RUN}" vagrant up verify-box --provider "${KUBE_PROVIDER}"
"${VAGRANT_RUN}" vagrant ssh verify-box -c 'id -u vagrant >/dev/null && test -d /home/vagrant'
"${VAGRANT_RUN}" vagrant destroy -f verify-box || true
popd >/dev/null

echo "[verify-box] OK: ${KUBE_BOX} boots and accepts Vagrant SSH"
