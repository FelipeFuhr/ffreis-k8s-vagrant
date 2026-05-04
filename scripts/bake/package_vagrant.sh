#!/usr/bin/env bash

bake_package_box_with_vagrant() {
  local box_file="${1}"
  if ! bake_run_vagrant package --output "${box_file}"; then
    return 1
  fi
  bake_validate_box_file "${box_file}"
}
