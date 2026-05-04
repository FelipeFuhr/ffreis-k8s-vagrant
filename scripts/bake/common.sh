#!/usr/bin/env bash

bake_require_host_cmd() {
  local cmd="${1}"
  local install_hint="${2}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[box] missing required host command: ${cmd}" >&2
    echo "[box] install hint: ${install_hint}" >&2
    exit 1
  fi
}

bake_run_vagrant() {
  if [[ -x "${VAGRANT_RETRY_SCRIPT}" ]]; then
    "${VAGRANT_RETRY_SCRIPT}" vagrant "$@"
  else
    vagrant "$@"
  fi
}

bake_restore_vagrant_insecure_key() {
  local vagrant_pub_key=""
  local key_path=""

  for key_path in /opt/vagrant/embedded/gems/gems/vagrant-*/keys/vagrant.pub; do
    if [[ -f "${key_path}" ]]; then
      vagrant_pub_key="$(head -n1 "${key_path}")"
      break
    fi
  done

  if [[ -z "${vagrant_pub_key}" ]]; then
    echo "[box] warning: could not find canonical vagrant insecure public key on host; skipping key restore" >&2
    return 0
  fi

  echo "[box] restoring canonical vagrant insecure SSH key in guest before packaging"
  bake_run_vagrant ssh "${BAKE_MACHINE_NAME}" -c "sudo install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh"
  bake_run_vagrant ssh "${BAKE_MACHINE_NAME}" -c "sudo bash -lc 'cat > /home/vagrant/.ssh/authorized_keys <<\"__KEY__\"
${vagrant_pub_key}
__KEY__
chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
chmod 0600 /home/vagrant/.ssh/authorized_keys'"
}

bake_validate_box_file() {
  local box_file="${1}"
  if [[ ! -s "${box_file}" ]]; then
    return 1
  fi
  tar -tzf "${box_file}" >/dev/null 2>&1
}

bake_ensure_min_free_gb() {
  local target_dir="${1}"
  local min_gb="${2}"
  local avail_kb=""
  local avail_gb=""
  avail_kb="$(df -Pk "${target_dir}" | awk 'NR==2 {print $4}')"
  if [[ -z "${avail_kb}" ]]; then
    return 0
  fi
  avail_gb=$((avail_kb / 1024 / 1024))
  if (( avail_gb < min_gb )); then
    echo "[box] insufficient free space at '${target_dir}': ${avail_gb}GiB available, need >= ${min_gb}GiB" >&2
    echo "[box] clean old images/boxes or set KUBE_BAKE_MIN_FREE_GB lower if you understand the risk" >&2
    exit 1
  fi
}

bake_prompt_yes_no() {
  local prompt="${1}"
  printf '%s [y/N] ' "${prompt}"
  read -r ans
  [[ "${ans}" =~ ^[Yy]$ ]]
}

bake_convert_disk_to_box_img() {
  local src_disk="${1}"
  local dst_img="${2}"

  if [[ -r "${src_disk}" ]]; then
    qemu-img convert -p -O qcow2 "${src_disk}" "${dst_img}"
    return 0
  fi

  echo "[box] source disk is not readable by current user: ${src_disk}" >&2
  if ! command -v sudo >/dev/null 2>&1; then
    echo "[box] sudo not found; cannot read libvirt disk owned by root/qemu" >&2
    return 1
  fi

  if ! bake_prompt_yes_no "[box] Root access is required to read libvirt image. Run qemu-img convert with sudo?"; then
    echo "[box] aborted by user" >&2
    return 1
  fi

  sudo qemu-img convert -p -O qcow2 "${src_disk}" "${dst_img}"
  sudo chown "$(id -u):$(id -g)" "${dst_img}"
}

bake_write_vagrantfile() {
  cat >"${BAKE_ROOT}/Vagrantfile" <<__VAGRANT__
Vagrant.configure("2") do |config|
  # Keep canonical insecure key in the baked image so first boot works reliably.
  config.ssh.insert_key = false
  config.vm.define "${BAKE_MACHINE_NAME}", primary: true do |node|
    node.vm.box = "${KUBE_BAKE_SOURCE_BOX}"
    node.vm.box_version = "${KUBE_BAKE_SOURCE_BOX_VERSION}" unless "${KUBE_BAKE_SOURCE_BOX_VERSION}".empty?
    node.vm.hostname = "${BAKE_MACHINE_NAME}"
    node.vm.synced_folder "${ROOT_DIR}", "/vagrant", type: "rsync"

    node.vm.provider "${KUBE_PROVIDER}" do |p|
      p.cpus = ${KUBE_BAKED_CPUS}
      p.memory = ${KUBE_BAKED_MEMORY}
    end

    node.vm.provision "shell", path: "${ROOT_DIR}/scripts/00_common.sh", env: {
      "NODE_ROLE" => "worker",
      "NODE_NAME" => "${BAKE_MACHINE_NAME}",
      "KUBE_VERSION" => "${KUBE_VERSION}",
      "KUBE_CHANNEL" => "${KUBE_CHANNEL}",
      "KUBE_CONTAINERD_VERSION" => "${KUBE_CONTAINERD_VERSION}",
      "KUBE_PAUSE_IMAGE" => "${KUBE_PAUSE_IMAGE}",
      "KUBE_APT_PROXY" => "${KUBE_APT_PROXY}"
    }
  end
end
__VAGRANT__
}
