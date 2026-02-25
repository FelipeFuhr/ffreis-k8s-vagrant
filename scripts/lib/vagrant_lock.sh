#!/usr/bin/env bash

vl_prompt_yes_no() {
  local prompt="$1"
  printf '%s [y/N] ' "${prompt}"
  read -r ans
  [[ "${ans}" =~ ^[Yy]$ ]]
}

vl_collect_vagrant_pids() {
  local self_pid parent_pid pid cmdline
  self_pid="$$"
  parent_pid="${PPID:-0}"

  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"${line}")"
    cmdline="$(cut -d' ' -f2- <<<"${line}")"

    if [[ -z "${pid}" || "${pid}" == "${self_pid}" || "${pid}" == "${parent_pid}" ]]; then
      continue
    fi

    if [[ "${cmdline}" == *"/opt/vagrant/bin/vagrant"* || "${cmdline}" == *"/usr/bin/vagrant"* || "${cmdline}" == *"ruby /opt/vagrant/embedded/gems/gems/vagrant"* ]]; then
      printf '%s\n' "${pid}"
    fi
  done < <(ps -eo pid=,args= | grep -E 'vagrant|ruby .*/vagrant' | grep -v grep || true)
}

vl_kill_stale_vagrant_processes() {
  local sudo_unlock_used="${1:-0}"
  local pid need_sudo=0

  while IFS= read -r pid; do
    kill -TERM "${pid}" >/dev/null 2>&1 || need_sudo=1
  done < <(vl_collect_vagrant_pids)

  if [[ "${need_sudo}" -eq 1 && "${sudo_unlock_used}" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
    if vl_prompt_yes_no "Stale Vagrant processes may need root privileges to stop. Run sudo cleanup?"; then
      while IFS= read -r pid; do
        sudo kill -TERM "${pid}" >/dev/null 2>&1 || true
      done < <(vl_collect_vagrant_pids)
      sudo_unlock_used=1
    fi
  fi

  sleep 1

  while IFS= read -r pid; do
    kill -KILL "${pid}" >/dev/null 2>&1 || true
  done < <(vl_collect_vagrant_pids)

  if command -v sudo >/dev/null 2>&1; then
    while IFS= read -r pid; do
      sudo kill -KILL "${pid}" >/dev/null 2>&1 || true
    done < <(vl_collect_vagrant_pids)
  fi

  echo "${sudo_unlock_used}"
}

vl_cleanup_stale_lock_files() {
  find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
  find "${HOME}/.vagrant.d/data/machine-index" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
}

vl_count_lock_files() {
  {
    find .vagrant -type f -name '*.lock' 2>/dev/null || true
    find "${HOME}/.vagrant.d/data/machine-index" -type f -name '*.lock' 2>/dev/null || true
  } | wc -l | tr -d ' '
}

vl_cleanup_stale_lock_files_with_sudo_if_needed() {
  local sudo_unlock_used="${1:-0}"
  local remaining

  vl_cleanup_stale_lock_files
  remaining="$(vl_count_lock_files)"

  if [[ "${remaining}" != "0" && "${sudo_unlock_used}" -eq 0 ]] && command -v sudo >/dev/null 2>&1; then
    if vl_prompt_yes_no "Stale lock files remain (${remaining}). Run sudo lock cleanup?"; then
      sudo find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
      sudo find "${HOME}/.vagrant.d/data/machine-index" -type f -name '*.lock' -delete >/dev/null 2>&1 || true
      sudo_unlock_used=1
    fi
  fi

  echo "${sudo_unlock_used}"
}

vl_is_lock_error() {
  local file="$1"
  grep -Eqi 'another process is already executing an action on the machine|vagrant locks each machine for access by only one process at a time|timed out while waiting for the machine lock|machine is locked|a lock is already held' "${file}"
}
