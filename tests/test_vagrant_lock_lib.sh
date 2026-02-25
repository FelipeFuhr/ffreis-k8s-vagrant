#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/scripts/lib/vagrant_lock.sh"

tmp_lock_msg="$(mktemp)"
cat >"${tmp_lock_msg}" <<'__MSG__'
An action 'up' was attempted on the machine 'cp1',
but another process is already executing an action on the machine.
Vagrant locks each machine for access by only one process at a time.
__MSG__

if ! vl_is_lock_error "${tmp_lock_msg}"; then
  echo "Expected lock message to be detected"
  exit 1
fi

tmp_other_msg="$(mktemp)"
cat >"${tmp_other_msg}" <<'__MSG__'
Some unrelated error
__MSG__

if vl_is_lock_error "${tmp_other_msg}"; then
  echo "Unexpected lock detection for unrelated message"
  exit 1
fi

count="$(vl_count_lock_files)"
if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
  echo "Expected numeric lock file count, got: ${count}"
  exit 1
fi

rm -f "${tmp_lock_msg}" "${tmp_other_msg}"
echo "Vagrant lock lib checks passed"
