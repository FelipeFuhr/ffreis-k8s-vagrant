#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/preflight.sh"

provider="${KUBE_PROVIDER:-libvirt}"
recommended_vagrant_major_minor="2.4"
recommended_vagrant_libvirt="0.12.2"

need_cmds=(vagrant)
if [[ "${provider}" == "libvirt" ]]; then
  need_cmds+=(virsh)
elif [[ "${provider}" == "virtualbox" ]]; then
  need_cmds+=(vboxmanage)
fi

failed=0
for cmd in "${need_cmds[@]}"; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: missing command '${cmd}'"
    failed=1
  else
    echo "OK: found ${cmd}"
  fi
done

if command -v vagrant >/dev/null 2>&1; then
  vagrant_version="$(vagrant --version 2>/dev/null | awk '{print $2}' | head -n1 || true)"
  if [[ -n "${vagrant_version}" ]]; then
    echo "INFO: detected Vagrant ${vagrant_version} (recommended family: ${recommended_vagrant_major_minor}.x)"
  fi

  if [[ "${provider}" == "libvirt" ]]; then
    if plugin_out="$(vagrant plugin list 2>/dev/null)"; then
      if ! grep -q vagrant-libvirt <<<"${plugin_out}"; then
        echo "ERROR: vagrant-libvirt plugin is not installed"
        failed=1
      else
        echo "OK: vagrant-libvirt plugin installed"
        installed_vagrant_libvirt="$(awk -F'[ ()]+' '/^vagrant-libvirt / {print $2; exit}' <<<"${plugin_out}")"
        if [[ -n "${installed_vagrant_libvirt}" && "${installed_vagrant_libvirt}" != "${recommended_vagrant_libvirt}" ]]; then
          echo "WARN: vagrant-libvirt ${installed_vagrant_libvirt} detected; tested set for this repo is ${recommended_vagrant_libvirt}"
          echo "WARN: if fog warnings or libvirt oddities persist, reinstall with:"
          echo "WARN:   vagrant plugin uninstall vagrant-libvirt && vagrant plugin install vagrant-libvirt --plugin-version ${recommended_vagrant_libvirt}"
        fi
      fi
    else
      echo "WARN: could not inspect Vagrant plugins (VAGRANT_HOME permission or initialization issue)"
    fi
  fi
fi

if [[ "${provider}" == "libvirt" ]]; then
  for host_cmd in virt-sysprep virt-sparsify qemu-img; do
    if ! command -v "${host_cmd}" >/dev/null 2>&1; then
      echo "WARN: missing '${host_cmd}' (needed for local box bake with 'make bake-box-vagrant')"
      echo "WARN: install with: sudo apt-get update && sudo apt-get install -y libguestfs-tools qemu-utils"
    else
      echo "OK: found ${host_cmd}"
    fi
  done
fi

if [[ "${failed}" -ne 0 ]]; then
  echo "Doctor checks failed"
  exit 1
fi

need_cpu="$(required_cpu_count)"
need_mem_gib="$(required_mem_gib)"
have_cpu="$(host_cpu_count)"
have_mem_gib="$(host_mem_gib)"
echo "INFO: topology requires ~= ${need_cpu} CPU and ${need_mem_gib} GiB host RAM"
echo "INFO: host detected ${have_cpu} CPU and ${have_mem_gib} GiB RAM"
if (( have_cpu < need_cpu )); then
  echo "WARN: host CPU may be insufficient for requested topology"
fi
if (( have_mem_gib < need_mem_gib )); then
  echo "WARN: host memory may be insufficient for requested topology"
fi
if conflict_msg="$(cidr_conflicts_host_routes)"; then
  suggestion="$(suggest_free_network_prefix)"
  echo "WARN: ${conflict_msg}"
  echo "WARN: suggested prefix: ${suggestion} (set KUBE_NETWORK_PREFIX and KUBE_API_LB_IP accordingly)"
fi

echo "Doctor checks passed"
