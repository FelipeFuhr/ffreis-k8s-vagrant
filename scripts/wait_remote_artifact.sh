#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <machine> <remote-path> [timeout-seconds] [poll-seconds]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_RETRY="${SCRIPT_DIR}/vagrant_retry.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/error.sh"
setup_error_trap "$(basename "${BASH_SOURCE[0]}")"

machine="${1}"
remote_path="${2}"
timeout_seconds="${3:-1200}"
poll_seconds="${4:-5}"
start_ts="$(date +%s)"

while true; do
  if "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "test -f '${remote_path}'" >/dev/null 2>&1; then
    exit 0
  fi

  if "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "test -f /vagrant/.cluster/failed" >/dev/null 2>&1; then
    echo "Control-plane bootstrap failed on ${machine}:" >&2
    "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "cat /vagrant/.cluster/failed" >&2 || true
    "${SCRIPT_DIR}/collect_failures.sh" >/dev/null 2>&1 || true
    exit 1
  fi

  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"
  if (( elapsed >= timeout_seconds )); then
    echo "Timed out waiting for ${remote_path} on ${machine} after ${elapsed}s" >&2
    if "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "test -f /vagrant/.cluster/cp1-progress" >/dev/null 2>&1; then
      echo "Latest bootstrap progress from ${machine}:" >&2
      "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "cat /vagrant/.cluster/cp1-progress" >&2 || true
    fi
    if "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "test -f /vagrant/.cluster/cp1-kubeadm.log" >/dev/null 2>&1; then
      echo "Recent kubeadm output from ${machine}:" >&2
      "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "tail -n 60 /vagrant/.cluster/cp1-kubeadm.log" >&2 || true
    fi
    "${SCRIPT_DIR}/collect_failures.sh" >/dev/null 2>&1 || true
    exit 1
  fi

  sleep "${poll_seconds}"
done
