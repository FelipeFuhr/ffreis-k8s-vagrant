#!/usr/bin/env bash
set -euo pipefail

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
TARGET_PATH="${1:?artifact path required}"

waited=0
report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
if [[ "${report_interval}" -lt "${SLEEP_SECONDS}" ]]; then
  report_interval="${SLEEP_SECONDS}"
fi
total_steps=$(((MAX_WAIT_SECONDS + report_interval - 1) / report_interval))
if [[ "${total_steps}" -lt 1 ]]; then
  total_steps=1
fi
while [[ ! -f "${TARGET_PATH}" ]]; do
  if (( waited == 0 || waited % report_interval == 0 )); then
    step=$((waited / report_interval + 1))
    if [[ "${step}" -gt "${total_steps}" ]]; then
      step="${total_steps}"
    fi
    echo "Waiting for ${TARGET_PATH} (${step}/${total_steps}, ${waited}s/${MAX_WAIT_SECONDS}s elapsed)" >&2
  fi

  if [[ -f /vagrant/.cluster/failed ]]; then
    echo "Control-plane bootstrap failed: $(cat /vagrant/.cluster/failed)" >&2
    echo "See host logs in .cluster/cp1-kubelet-error.log or .cluster/cp1-kubelet-init.log" >&2
    exit 1
  fi

  if [[ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]]; then
    echo "Timed out waiting for ${TARGET_PATH}" >&2
    if [[ -f /vagrant/.cluster/cp1-kubelet-error.log ]]; then
      echo "Control-plane error log already collected at .cluster/cp1-kubelet-error.log" >&2
    fi
    exit 1
  fi

  sleep "${SLEEP_SECONDS}"
  waited=$((waited + SLEEP_SECONDS))
done
