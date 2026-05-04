#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/vagrant_lock.sh"

max_attempts="${KUBE_VAGRANT_RETRY_ATTEMPTS:-${VAGRANT_RETRY_ATTEMPTS:-10}}"
base_sleep_seconds="${KUBE_VAGRANT_RETRY_SLEEP_SECONDS:-${VAGRANT_RETRY_SLEEP_SECONDS:-15}}"
backoff_factor="${KUBE_VAGRANT_RETRY_BACKOFF_FACTOR:-${VAGRANT_RETRY_BACKOFF_FACTOR:-2}}"
max_sleep_seconds="${KUBE_VAGRANT_RETRY_MAX_SLEEP_SECONDS:-${VAGRANT_RETRY_MAX_SLEEP_SECONDS:-120}}"
max_total_retry_seconds="${KUBE_VAGRANT_RETRY_MAX_TOTAL_SECONDS:-${VAGRANT_RETRY_MAX_TOTAL_SECONDS:-1800}}"
hide_known_fog_warning="${KUBE_HIDE_KNOWN_FOG_WARNING:-true}"
force_unlock_used=0
sudo_unlock_used=0

compute_sleep_seconds() {
  local attempt_idx="$1"
  local sleep_value="${base_sleep_seconds}"
  local i

  for ((i = 1; i < attempt_idx; i++)); do
    sleep_value=$((sleep_value * backoff_factor))
    if ((sleep_value >= max_sleep_seconds)); then
      sleep_value="${max_sleep_seconds}"
      break
    fi
  done

  echo "${sleep_value}"
}

attempt=1
start_ts="$(date +%s)"
while true; do
  output_file="$(mktemp)"
  run_cmd=(env -u VAGRANT_LIBVIRT_CPU_VENDOR -u VAGRANT_LIBVIRT_CPU_MODEL "$@")
  if [[ "${hide_known_fog_warning}" == "true" ]]; then
    fog_warn_pattern='^\[fog\]\[WARNING\].*libvirt_ip_command.*$'
    if "${run_cmd[@]}" \
      > >(tee "${output_file}" | sed -E "/${fog_warn_pattern}/d") \
      2> >(tee -a "${output_file}" >&2 | sed -E "/${fog_warn_pattern}/d" >&2); then
      rm -f "${output_file}"
      exit 0
    fi
  elif "${run_cmd[@]}" > >(tee "${output_file}") 2> >(tee -a "${output_file}" >&2); then
    rm -f "${output_file}"
    exit 0
  fi

  is_transient_timeout_error=0
  if grep -Eqi 'Fog::Errors::TimeoutError|specified wait_for timeout|Waiting for domain to get an IP address' "${output_file}"; then
    is_transient_timeout_error=1
  fi

  if vl_is_lock_error "${output_file}" || [[ "${is_transient_timeout_error}" -eq 1 ]]; then
    rm -f "${output_file}"
    now_ts="$(date +%s)"
    elapsed_seconds=$((now_ts - start_ts))

    if [[ "${attempt}" -ge "${max_attempts}" && "${elapsed_seconds}" -ge "${max_total_retry_seconds}" ]]; then
      if [[ "${force_unlock_used}" -eq 0 ]]; then
        if vl_prompt_yes_no "Persistent Vagrant lock detected. Kill stale vagrant/ruby processes and retry once?"; then
          sudo_unlock_used="$(vl_kill_stale_vagrant_processes "${sudo_unlock_used}")"
          sudo_unlock_used="$(vl_cleanup_stale_lock_files_with_sudo_if_needed "${sudo_unlock_used}")"
          force_unlock_used=1
          attempt=1
          start_ts="$(date +%s)"
          continue
        fi
      fi

      echo "Vagrant command failed after ${elapsed_seconds}s lock retries and ${attempt} attempts: $*" >&2
      exit 1
    fi

    retry_sleep_seconds="$(compute_sleep_seconds "${attempt}")"
    if [[ "${is_transient_timeout_error}" -eq 1 ]]; then
      echo "Transient Vagrant/libvirt timeout detected (attempt ${attempt}, elapsed ${elapsed_seconds}s); retrying in ${retry_sleep_seconds}s..." >&2
    else
      echo "Vagrant lock detected (attempt ${attempt}, elapsed ${elapsed_seconds}s); retrying in ${retry_sleep_seconds}s..." >&2
      sudo_unlock_used="$(vl_cleanup_stale_lock_files_with_sudo_if_needed "${sudo_unlock_used}")"
    fi
    sleep "${retry_sleep_seconds}"
    attempt=$((attempt + 1))
    continue
  fi

  rm -f "${output_file}"
  exit 1
done
