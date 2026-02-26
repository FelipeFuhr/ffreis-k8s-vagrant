#!/usr/bin/env bash
set -euo pipefail

./examples/check_control_plane_connectivity.sh --self-test success >/dev/null

if ./examples/check_control_plane_connectivity.sh --self-test failure >/dev/null 2>&1; then
  echo "Expected --self-test failure to return non-zero"
  exit 1
fi

echo "Example script tests passed"
