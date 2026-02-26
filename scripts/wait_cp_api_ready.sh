#!/usr/bin/env bash
set -euo pipefail

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-420}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
VAGRANT_BIN="${VAGRANT_BIN:-vagrant}"

log_wait_progress() {
  local label="$1"
  local waited="$2"
  local timeout="$3"
  local report_interval="$4"
  local step total_steps

  total_steps=$(((timeout + report_interval - 1) / report_interval))
  if [[ "${total_steps}" -lt 1 ]]; then
    total_steps=1
  fi

  step=$((waited / report_interval + 1))
  if [[ "${step}" -gt "${total_steps}" ]]; then
    step="${total_steps}"
  fi

  echo "${label} (${step}/${total_steps}, ${waited}s/${timeout}s elapsed)"
}

waited=0
report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
if [[ "${report_interval}" -lt "${SLEEP_SECONDS}" ]]; then
  report_interval="${SLEEP_SECONDS}"
fi

while true; do
  if ${VAGRANT_BIN} ssh cp1 -c 'sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw=/readyz >/dev/null 2>&1'; then
    if [[ "${waited}" -gt 0 ]]; then
      echo "Control-plane API is ready after ${waited}s"
    fi
    exit 0
  fi

  if (( waited == 0 || waited % report_interval == 0 )); then
    log_wait_progress "Waiting for control-plane API readiness" "${waited}" "${MAX_WAIT_SECONDS}" "${report_interval}"
  fi

  if [[ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]]; then
    echo "Timed out waiting for control-plane API readiness" >&2
    exit 1
  fi

  sleep "${SLEEP_SECONDS}"
  waited=$((waited + SLEEP_SECONDS))
done
