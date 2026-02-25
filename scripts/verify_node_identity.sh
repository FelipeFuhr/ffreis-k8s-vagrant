#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <machine> <expected-hostname> <expected-ip>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_RETRY="${SCRIPT_DIR}/vagrant_retry.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/node_contract.sh"

machine="${1}"
expected_host="${2}"
expected_ip="${3}"

actual_host="$(node_actual_hostname "${machine}" "${VAGRANT_RETRY}")"
if [[ "${actual_host}" != "${expected_host}" ]]; then
  echo "Node identity mismatch for ${machine}: expected hostname '${expected_host}', got '${actual_host:-<empty>}'" >&2
  echo "Remediation: make destroy && rm -rf .vagrant && make up" >&2
  exit 1
fi

if ! node_has_expected_ip "${machine}" "${expected_ip}" "${VAGRANT_RETRY}"; then
  echo "Node IP mismatch for ${machine}: expected '${expected_ip}/24'" >&2
  echo "Observed IPv4 addresses:" >&2
  "${VAGRANT_RETRY}" vagrant ssh "${machine}" -c "ip -o -4 addr show" >&2 || true
  echo "Remediation: make destroy && rm -rf .vagrant && make up" >&2
  exit 1
fi

echo "[verify-node] ${machine} hostname/ip OK (${expected_host}, ${expected_ip})"
