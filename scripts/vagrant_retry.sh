#!/usr/bin/env bash
set -euo pipefail

max_attempts="${KUBE_VAGRANT_RETRY_ATTEMPTS:-${VAGRANT_RETRY_ATTEMPTS:-10}}"
base_sleep_seconds="${KUBE_VAGRANT_RETRY_SLEEP_SECONDS:-${VAGRANT_RETRY_SLEEP_SECONDS:-15}}"
backoff_factor="${KUBE_VAGRANT_RETRY_BACKOFF_FACTOR:-${VAGRANT_RETRY_BACKOFF_FACTOR:-2}}"
max_sleep_seconds="${KUBE_VAGRANT_RETRY_MAX_SLEEP_SECONDS:-${VAGRANT_RETRY_MAX_SLEEP_SECONDS:-120}}"
max_total_retry_seconds="${KUBE_VAGRANT_RETRY_MAX_TOTAL_SECONDS:-${VAGRANT_RETRY_MAX_TOTAL_SECONDS:-1800}}"
hide_known_fog_warning="${KUBE_HIDE_KNOWN_FOG_WARNING:-true}"
lock_pattern="another process is already executing an action on the machine"
force_unlock_used=0

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

kill_stale_vagrant_processes() {
  local self_pid parent_pid pid cmdline
  self_pid="$$"
  parent_pid="${PPID:-0}"

  # Target concrete Vagrant executables or embedded Ruby Vagrant launcher only.
  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"${line}")"
    cmdline="$(cut -d' ' -f2- <<<"${line}")"

    if [[ -z "${pid}" || "${pid}" == "${self_pid}" || "${pid}" == "${parent_pid}" ]]; then
      continue
    fi

    if [[ "${cmdline}" == *"/opt/vagrant/bin/vagrant"* || "${cmdline}" == *"/usr/bin/vagrant"* || "${cmdline}" == *"ruby /opt/vagrant/embedded/gems/gems/vagrant"* ]]; then
      kill -TERM "${pid}" >/dev/null 2>&1 || true
    fi
  done < <(ps -eo pid=,args= | grep -E 'vagrant|ruby .*/vagrant' | grep -v grep || true)

  sleep 1

  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"${line}")"
    cmdline="$(cut -d' ' -f2- <<<"${line}")"

    if [[ -z "${pid}" || "${pid}" == "${self_pid}" || "${pid}" == "${parent_pid}" ]]; then
      continue
    fi

    if [[ "${cmdline}" == *"/opt/vagrant/bin/vagrant"* || "${cmdline}" == *"/usr/bin/vagrant"* || "${cmdline}" == *"ruby /opt/vagrant/embedded/gems/gems/vagrant"* ]]; then
      kill -KILL "${pid}" >/dev/null 2>&1 || true
    fi
  done < <(ps -eo pid=,args= | grep -E 'vagrant|ruby .*/vagrant' | grep -v grep || true)
}

attempt=1
start_ts="$(date +%s)"
while true; do
  output_file="$(mktemp)"
  if [[ "${hide_known_fog_warning}" == "true" ]]; then
    fog_warn_pattern='^\[fog\]\[WARNING\].*libvirt_ip_command.*$'
    if "$@" \
      > >(tee "${output_file}" | sed -E "/${fog_warn_pattern}/d") \
      2> >(tee -a "${output_file}" >&2 | sed -E "/${fog_warn_pattern}/d" >&2); then
      rm -f "${output_file}"
      exit 0
    fi
  elif "$@" > >(tee "${output_file}") 2> >(tee -a "${output_file}" >&2); then
    rm -f "${output_file}"
    exit 0
  fi

  if grep -qi "${lock_pattern}" "${output_file}"; then
    rm -f "${output_file}"
    now_ts="$(date +%s)"
    elapsed_seconds=$((now_ts - start_ts))

    # Keep retrying at capped backoff until we hit total retry time budget.
    if [[ "${attempt}" -ge "${max_attempts}" && "${elapsed_seconds}" -ge "${max_total_retry_seconds}" ]]; then
      if [[ "${force_unlock_used}" -eq 0 ]]; then
        printf 'Persistent Vagrant lock detected. Kill stale vagrant/ruby processes and retry once? [y/N] '
        read -r ans
        if [[ "${ans}" =~ ^[Yy]$ ]]; then
          kill_stale_vagrant_processes
          find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
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
    echo "Vagrant lock detected (attempt ${attempt}, elapsed ${elapsed_seconds}s); retrying in ${retry_sleep_seconds}s..." >&2
    sleep "${retry_sleep_seconds}"
    attempt=$((attempt + 1))
    continue
  fi

  rm -f "${output_file}"
  exit 1
done
