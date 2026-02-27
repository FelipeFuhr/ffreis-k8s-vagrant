#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [[ "${expected}" != "${actual}" ]]; then
    echo "Assertion failed for ${label}: expected=${expected}, actual=${actual}" >&2
    exit 1
  fi
}

fixture="tests/fixtures/vagrant-nodes-sample.json"

resolved_endpoints="$(
  NODES_FILE="${fixture}" ./scripts/resolve_etcd_endpoints.sh --format endpoints
)"
assert_eq "http://10.44.0.31:2379,http://10.44.0.32:2379,http://10.44.0.33:2379" "${resolved_endpoints}" "resolver endpoints from nodes fixture"

resolved_nodes="$(
  NODES_FILE="${fixture}" ./scripts/resolve_etcd_endpoints.sh --format nodes
)"
expected_nodes=$'etcd1 10.44.0.31\netcd2 10.44.0.32\netcd3 10.44.0.33'
assert_eq "${expected_nodes}" "${resolved_nodes}" "resolver nodes from nodes fixture"

env_endpoints="http://1.1.1.1:2379,http://2.2.2.2:2379"
resolved_env_endpoints="$(
  EXTERNAL_ETCD_ENDPOINTS="${env_endpoints}" NODES_FILE="${fixture}" ./scripts/resolve_etcd_endpoints.sh --format endpoints
)"
assert_eq "${env_endpoints}" "${resolved_env_endpoints}" "resolver endpoints env override"

fallback_endpoints="$(
  NODES_FILE="/tmp/nonexistent-vagrant-nodes.json" KUBE_NETWORK_PREFIX="10.55.0" KUBE_ETCD_COUNT=2 ./scripts/resolve_etcd_endpoints.sh --format endpoints
)"
assert_eq "http://10.55.0.21:2379,http://10.55.0.22:2379" "${fallback_endpoints}" "resolver endpoints fallback"

echo "etcd endpoint resolver tests passed"
