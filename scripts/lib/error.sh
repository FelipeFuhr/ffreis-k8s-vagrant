#!/usr/bin/env bash

err_log() {
  local node_name script_name line_no exit_code
  node_name="${NODE_NAME:-$(hostname -s)}"
  script_name="${CURRENT_SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-${0}}")}" 
  line_no="${1:-unknown}"
  exit_code="${2:-1}"
  printf '[%s] ERROR: %s failed at line %s (exit %s)\n' "${node_name}" "${script_name}" "${line_no}" "${exit_code}" >&2
}

setup_error_trap() {
  CURRENT_SCRIPT_NAME="${1:-$(basename "$0")}" 
  trap 'err_log "${LINENO}" "$?"' ERR
}
