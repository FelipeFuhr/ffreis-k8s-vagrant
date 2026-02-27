#!/usr/bin/env bash
set -euo pipefail

max_attempts="${VAGRANT_RETRY_ATTEMPTS:-10}"
sleep_seconds="${VAGRANT_RETRY_SLEEP_SECONDS:-6}"
lock_pattern="another process is already executing an action on the machine"
fog_warn_literal='[fog][WARNING] Unrecognized arguments: libvirt_ip_command'
# auto_unlock_mode:
# - prompt (default): ask before killing stale local vagrant/ruby processes.
# - true: auto-kill without prompt.
# - false: never kill automatically.
auto_unlock_mode="${VAGRANT_RETRY_AUTO_UNLOCK:-prompt}"
force_unlock_used=0

list_vagrant_processes() {
  pgrep -af '(/opt/vagrant/bin/vagrant|/usr/bin/vagrant|ruby /opt/vagrant/embedded/gems/gems/vagrant)' || true
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
  done < <(list_vagrant_processes)

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
  done < <(list_vagrant_processes)
}

attempt=1
while true; do
  output_file="$(mktemp)"

  if "$@" > >(grep -vF "${fog_warn_literal}" | tee "${output_file}") \
    2> >(grep -vF "${fog_warn_literal}" | tee -a "${output_file}" >&2); then
    rm -f "${output_file}"
    exit 0
  fi

  if grep -qi "${lock_pattern}" "${output_file}"; then
    rm -f "${output_file}"

    if [[ "${attempt}" -ge "${max_attempts}" ]]; then
      if [[ "${force_unlock_used}" -eq 0 ]]; then
        should_unlock="false"

        if [[ "${auto_unlock_mode}" == "true" ]]; then
          should_unlock="true"
        elif [[ "${auto_unlock_mode}" == "auto" || "${auto_unlock_mode}" == "prompt" ]]; then
          printf 'Persistent Vagrant lock detected. Kill stale vagrant/ruby processes and retry once? [y/N] '
          read -r ans
          if [[ "${ans}" =~ ^[Yy]$ ]]; then
            should_unlock="true"
          fi
        fi

        if [[ "${should_unlock}" == "true" ]]; then
          kill_stale_vagrant_processes
          find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
          force_unlock_used=1
          attempt=1
          continue
        fi
      fi

      echo "Vagrant command failed after ${max_attempts} lock-retry attempts: $*" >&2
      exit 1
    fi

    echo "Vagrant lock detected (attempt ${attempt}/${max_attempts}); retrying in ${sleep_seconds}s..." >&2
    sleep "${sleep_seconds}"
    attempt=$((attempt + 1))
    continue
  fi

  rm -f "${output_file}"
  exit 1
done
