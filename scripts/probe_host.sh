#!/usr/bin/env bash
set -euo pipefail

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

cpu_model="unknown"
cpu_vendor="unknown"
if [[ -f /proc/cpuinfo ]]; then
  cpu_model="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo)"
  cpu_vendor="$(awk -F': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)"
fi

mem_gb="unknown"
if [[ -f /proc/meminfo ]]; then
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  mem_gb="$((mem_kb / 1024 / 1024))"
fi

provider_candidates=()
if have_cmd vboxmanage; then
  provider_candidates+=("virtualbox")
fi
if have_cmd virsh || have_cmd qemu-system-x86_64; then
  provider_candidates+=("libvirt")
fi

vagrant_plugins=""
if have_cmd vagrant; then
  vagrant_plugins="$(vagrant plugin list 2>/dev/null || true)"
fi

vmx_svm="no"
if grep -Eq '(vmx|svm)' /proc/cpuinfo; then
  vmx_svm="yes"
fi

printf 'Host probe\n'
printf 'Date: %s\n' "$(date -Iseconds)"
printf 'CPU model: %s\n' "${cpu_model}"
printf 'CPU vendor: %s\n' "${cpu_vendor}"
printf 'Virtualization flags present: %s\n' "${vmx_svm}"
printf 'Memory (GiB): %s\n' "${mem_gb}"
printf 'Candidates providers: %s\n' "${provider_candidates[*]:-none}"
printf 'Vagrant installed: %s\n' "$(have_cmd vagrant && echo yes || echo no)"
printf 'kubectl installed: %s\n' "$(have_cmd kubectl && echo yes || echo no)"
printf '\n'

if [[ "${vmx_svm}" != "yes" ]]; then
  printf 'WARN: CPU virtualization extensions not detected. Nested virtualization may be disabled in BIOS/UEFI.\n'
fi

if [[ "${mem_gb}" != "unknown" ]]; then
  if (( mem_gb < 16 )); then
    printf 'WARN: <16GiB RAM. Start with KUBE_CP_COUNT=1 and KUBE_WORKER_COUNT=1.\n'
  elif (( mem_gb < 24 )); then
    printf 'INFO: 16-23GiB RAM. Recommended KUBE_CP_COUNT=1 and KUBE_WORKER_COUNT=2.\n'
  else
    printf 'INFO: >=24GiB RAM. You can likely run KUBE_CP_COUNT=3 and KUBE_WORKER_COUNT=2.\n'
  fi
fi

if [[ -n "${vagrant_plugins}" ]]; then
  printf '\nVagrant plugins:\n%s\n' "${vagrant_plugins}"
fi
