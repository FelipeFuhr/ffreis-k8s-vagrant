#!/usr/bin/env bash

run_with_backoff_retry_loop() {
  local retry_attempts="$1"
  local retry_base_sleep_seconds="$2"
  local retry_backoff_factor="$3"
  local retry_max_sleep_seconds="$4"
  local retry_max_total_seconds="$5"
  local try_function="$6"
  local on_failure_function="$7"
  local attempt=1
  local start_ts now_ts elapsed_seconds retry_sleep_seconds

  start_ts="$(date +%s)"
  while true; do
    if "${try_function}"; then
      return 0
    fi

    now_ts="$(date +%s)"
    elapsed_seconds=$((now_ts - start_ts))
    if [[ "${attempt}" -ge "${retry_attempts}" && "${elapsed_seconds}" -ge "${retry_max_total_seconds}" ]]; then
      echo "Retry loop failed after ${attempt} attempts and ${elapsed_seconds}s elapsed" >&2
      return 1
    fi

    "${on_failure_function}" "${attempt}" "${elapsed_seconds}"
    retry_sleep_seconds="$(compute_backoff_sleep_seconds "${attempt}" "${retry_base_sleep_seconds}" "${retry_backoff_factor}" "${retry_max_sleep_seconds}")"
    sleep "${retry_sleep_seconds}"
    attempt=$((attempt + 1))
  done
}
