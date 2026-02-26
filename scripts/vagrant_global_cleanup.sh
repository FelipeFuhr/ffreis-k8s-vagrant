#!/usr/bin/env bash
set -euo pipefail

target_dir="${1:-$(pwd)}"
target_dir="$(cd "${target_dir}" && pwd)"

if ! command -v vagrant >/dev/null 2>&1; then
  exit 0
fi

vagrant global-status --prune >/dev/null 2>&1 || true

mapfile -t ids < <(
  vagrant global-status 2>/dev/null \
    | awk -v dir="${target_dir}" '
      /^-+$/ {sep++; next}
      sep < 1 {next}
      NF < 5 {next}
      {
        id=$1
        path=$NF
        if (path == dir) {
          print id
        }
      }
    '
)

for id in "${ids[@]:-}"; do
  [[ -n "${id}" ]] || continue
  vagrant destroy -f "${id}" >/dev/null 2>&1 || true
done
