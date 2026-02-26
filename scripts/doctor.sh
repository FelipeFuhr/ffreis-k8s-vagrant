#!/usr/bin/env bash
set -euo pipefail

provider="${KUBE_PROVIDER:-libvirt}"

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
  if [[ "${provider}" == "libvirt" ]]; then
    if plugin_out="$(vagrant plugin list 2>/dev/null)"; then
      if ! grep -q vagrant-libvirt <<<"${plugin_out}"; then
        echo "ERROR: vagrant-libvirt plugin is not installed"
        failed=1
      else
        echo "OK: vagrant-libvirt plugin installed"
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
