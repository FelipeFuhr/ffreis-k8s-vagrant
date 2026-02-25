#!/usr/bin/env bash

bake_package_box_without_libguestfs() {
  local bake_dir="${1}"
  local box_file="${2}"
  local machine_id=""
  local domain=""
  local disk_path=""
  local tmpdir=""
  local img_size=""

  if [[ ! -f "${bake_dir}/.vagrant/machines/${BAKE_MACHINE_NAME}/libvirt/id" ]]; then
    echo "[box] cannot find libvirt machine id for manual packaging" >&2
    return 1
  fi
  machine_id="$(tr -d '\r\n' <"${bake_dir}/.vagrant/machines/${BAKE_MACHINE_NAME}/libvirt/id")"
  if [[ -z "${machine_id}" ]]; then
    echo "[box] empty libvirt machine id for manual packaging" >&2
    return 1
  fi

  domain="$(virsh domname "${machine_id}" 2>/dev/null || true)"
  if [[ -z "${domain}" ]]; then
    echo "[box] failed to resolve domain name from machine id '${machine_id}'" >&2
    return 1
  fi

  disk_path="$(virsh domblklist "${domain}" --details 2>/dev/null | awk '$1=="file" && $2=="disk" && $3=="vda" {print $4; exit}')"
  if [[ -z "${disk_path}" ]]; then
    disk_path="$(virsh domblklist "${domain}" --details 2>/dev/null | awk '$1=="file" && $2=="disk" {print $4; exit}')"
  fi
  if [[ -z "${disk_path}" || ! -f "${disk_path}" ]]; then
    echo "[box] failed to locate root disk for domain '${domain}'" >&2
    return 1
  fi

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' RETURN
  bake_ensure_min_free_gb "${tmpdir}" "${KUBE_BAKE_MIN_FREE_GB}"
  bake_ensure_min_free_gb "${BOX_DIR}" "${KUBE_BAKE_MIN_FREE_GB}"

  echo "[box] manual package: flattening qcow2 image from '${disk_path}'"
  bake_convert_disk_to_box_img "${disk_path}" "${tmpdir}/box.img"

  img_size="$(qemu-img info --output=json "${tmpdir}/box.img" | tr -d ' \n' | sed -n 's/.*"virtual-size":\([0-9][0-9]*\).*/\1/p')"
  if [[ -z "${img_size}" || "${img_size}" == "null" ]]; then
    echo "[box] failed to read image size for manual package" >&2
    return 1
  fi
  img_size=$(( (img_size + 1024*1024*1024 - 1) / (1024*1024*1024) ))

  cat >"${tmpdir}/metadata.json" <<__JSON__
{
  "provider": "libvirt",
  "format": "qcow2",
  "virtual_size": ${img_size}
}
__JSON__

  cat >"${tmpdir}/Vagrantfile" <<'__VAGRANT__'
Vagrant.configure("2") do |config|
  config.vm.provider :libvirt do |libvirt|
    libvirt.driver = "kvm"
  end
end
__VAGRANT__

  mkdir -p "$(dirname "${box_file}")"
  rm -f "${box_file}"
  tar -czf "${box_file}" -C "${tmpdir}" box.img metadata.json Vagrantfile
  echo "[box] manual package created at '${box_file}'"
}
