#!/usr/bin/env bash
set -euo pipefail

PROJECT_PREFIX="${1:-ffreis-k8s-vagrant-lab_}"
NETWORK_PREFIX="${2:-}"

cleanup_with_prefix() {
  local virsh_cmd="$1"
  local dom
  local pool
  local vol
  local net
  local xml

  for dom in $(${virsh_cmd} list --all --name | grep "^${PROJECT_PREFIX}" || true); do
    ${virsh_cmd} destroy "${dom}" >/dev/null 2>&1 || true
    ${virsh_cmd} undefine "${dom}" --nvram --remove-all-storage >/dev/null 2>&1 || true
    ${virsh_cmd} undefine "${dom}" --nvram >/dev/null 2>&1 || ${virsh_cmd} undefine "${dom}" >/dev/null 2>&1 || true
  done

  for pool in $(${virsh_cmd} pool-list --all --name | sed '/^$/d'); do
    for vol in $(${virsh_cmd} vol-list "${pool}" --name 2>/dev/null | grep -E "^${PROJECT_PREFIX}|${PROJECT_PREFIX##*_}" || true); do
      ${virsh_cmd} vol-delete --pool "${pool}" "${vol}" >/dev/null 2>&1 || true
    done
  done

  if [[ -n "${NETWORK_PREFIX}" ]]; then
    for net in $(${virsh_cmd} net-list --all --name | sed '/^$/d'); do
      xml="$(${virsh_cmd} net-dumpxml "${net}" 2>/dev/null || true)"
      if [[ -z "${xml}" ]]; then
        continue
      fi
      if ! grep -Eq "<ip address=['\"]${NETWORK_PREFIX//./\\.}\\.[0-9]+['\"]" <<<"${xml}"; then
        continue
      fi
      ${virsh_cmd} net-autostart --disable "${net}" >/dev/null 2>&1 || true
      ${virsh_cmd} net-destroy "${net}" >/dev/null 2>&1 || true
      ${virsh_cmd} net-undefine "${net}" >/dev/null 2>&1 || true
    done
  fi
}

if ! command -v virsh >/dev/null 2>&1; then
  exit 0
fi

if virsh list --all --name >/dev/null 2>&1; then
  cleanup_with_prefix "virsh"
  exit 0
fi

err_out="$(virsh list --all --name 2>&1 || true)"
if grep -Eiq 'operation not permitted|permission denied|failed to connect socket|libvirt-sock' <<<"${err_out}"; then
  printf 'libvirt cleanup needs elevation. Run virsh cleanup with sudo? [y/N] '
  read -r ans
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
    if sudo -n true >/dev/null 2>&1; then
      cleanup_with_prefix "sudo virsh"
      exit 0
    fi

    echo "Requesting sudo password for libvirt cleanup..."
    cleanup_with_prefix "sudo virsh"
    exit 0
  fi

  echo "Skipping elevated libvirt cleanup."
  exit 0
fi

echo "virsh unavailable for cleanup: ${err_out}" >&2
exit 0
