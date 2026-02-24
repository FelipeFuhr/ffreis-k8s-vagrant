#!/usr/bin/env bash
set -euo pipefail

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

if [[ "${failed}" -ne 0 ]]; then
  echo "Doctor checks failed"
  exit 1
fi

echo "Doctor checks passed"
