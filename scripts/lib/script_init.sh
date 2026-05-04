#!/usr/bin/env bash

init_script_lib_dir() {
  local caller_path="${1:-${BASH_SOURCE[1]}}"
  SCRIPT_DIR="$(cd "$(dirname "${caller_path}")" && pwd)"
  LIB_DIR="/vagrant/scripts/lib"
  if [[ ! -d "${LIB_DIR}" ]]; then
    LIB_DIR="${SCRIPT_DIR}/lib"
  fi
}

source_script_libs() {
  local lib
  for lib in "$@"; do
    # shellcheck disable=SC1090
    source "${LIB_DIR}/${lib}.sh"
  done
}
