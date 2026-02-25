#!/usr/bin/env bash

STATE_DIR="${STATE_DIR:-.cluster}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.env}"

state_init() {
  mkdir -p "${STATE_DIR}"
  local run_id
  run_id="$(date +%Y%m%d%H%M%S)-$RANDOM"
  cat >"${STATE_FILE}" <<ENV
CLUSTER_RUN_ID=${run_id}
CLUSTER_STARTED_AT=$(date -Iseconds)
ENV
}

state_set() {
  local key="$1"
  local value="$2"
  mkdir -p "${STATE_DIR}"
  touch "${STATE_FILE}"
  if grep -q "^${key}=" "${STATE_FILE}"; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "${STATE_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${STATE_FILE}"
  fi
}

state_get() {
  local key="$1"
  [[ -f "${STATE_FILE}" ]] || return 1
  awk -F'=' -v k="${key}" '$1==k {print substr($0, index($0,$2)); exit}' "${STATE_FILE}"
}
