#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /vagrant/scripts/lib/script_init.sh ]]; then
  # shellcheck disable=SC1091
  source /vagrant/scripts/lib/script_init.sh
else
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/script_init.sh"
fi
init_script_lib_dir "${BASH_SOURCE[0]}"
source_script_libs logging retry error
if [[ -f /vagrant/scripts/node/base_common.sh ]]; then
  # shellcheck disable=SC1091
  source /vagrant/scripts/node/base_common.sh
else
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/node/base_common.sh"
fi
setup_error_trap "$(basename "${BASH_SOURCE[0]}")"

run_base_common_provision
