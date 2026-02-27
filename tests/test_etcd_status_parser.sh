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

parse_unique() {
  ./scripts/parse_etcd_endpoint_status.sh --field unique_ids "$1"
}

parse_leaders() {
  ./scripts/parse_etcd_endpoint_status.sh --field leaders "$1"
}

fixture1="tests/fixtures/etcd-status-id-isleader.json"
fixture2="tests/fixtures/etcd-status-memberid-leader.json"

assert_eq "3" "$(parse_unique "${fixture1}")" "fixture1 unique_ids"
assert_eq "1" "$(parse_leaders "${fixture1}")" "fixture1 leaders"

assert_eq "3" "$(parse_unique "${fixture2}")" "fixture2 unique_ids"
assert_eq "1" "$(parse_leaders "${fixture2}")" "fixture2 leaders"

echo "etcd endpoint status parser tests passed"
