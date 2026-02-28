#!/usr/bin/env bash
set -euo pipefail

KUBE_ETCD_COUNT="${KUBE_ETCD_COUNT:-3}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-420}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
PRIMARY_ETCD_NAME="${PRIMARY_ETCD_NAME:-etcd1}"

vagrant_cmd() {
  ./scripts/vagrant_retry.sh vagrant "$@"
}

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

endpoints="$(./scripts/resolve_etcd_endpoints.sh --format endpoints)"
waited=0
report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
if [[ "${report_interval}" -lt "${SLEEP_SECONDS}" ]]; then
  report_interval="${SLEEP_SECONDS}"
fi

while true; do
  health_ok=0
  member_count=0
  unique_ids=0
  leader_count=0

  if vagrant_cmd ssh "${PRIMARY_ETCD_NAME}" -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint health >/dev/null 2>&1"; then
    health_ok=1
  fi

  member_list="$(vagrant_cmd ssh "${PRIMARY_ETCD_NAME}" -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} member list" 2>/dev/null || true)"
  member_count="$(printf '%s\n' "${member_list}" | sed '/^$/d' | wc -l | tr -dc '0-9')"
  [[ -n "${member_count}" ]] || member_count=0

  status_json="$(vagrant_cmd ssh "${PRIMARY_ETCD_NAME}" -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint status -w json" 2>/dev/null || true)"
  if [[ -n "${status_json}" ]]; then
    unique_ids="$(printf '%s' "${status_json}" | ./scripts/parse_etcd_endpoint_status.sh --field unique_ids || true)"
    leader_count="$(printf '%s' "${status_json}" | ./scripts/parse_etcd_endpoint_status.sh --field leaders || true)"
  else
    unique_ids=0
    leader_count=0
  fi
  [[ -n "${unique_ids}" ]] || unique_ids=0
  [[ -n "${leader_count}" ]] || leader_count=0

  if [[ "${health_ok}" -eq 1 && "${member_count}" -eq "${KUBE_ETCD_COUNT}" && "${unique_ids}" -eq "${KUBE_ETCD_COUNT}" && "${leader_count}" -eq 1 ]]; then
    if [[ "${waited}" -gt 0 ]]; then
      echo "External etcd cluster is healthy after ${waited}s"
    fi
    exit 0
  fi

  if (( waited == 0 || waited % report_interval == 0 )); then
    log_wait_progress "Waiting for external etcd cluster health (health=${health_ok}, members=${member_count}/${KUBE_ETCD_COUNT}, uniqueIDs=${unique_ids}, leaders=${leader_count})" "${waited}" "${MAX_WAIT_SECONDS}" "${report_interval}"
  fi

  if [[ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]]; then
    echo "Timed out waiting for external etcd cluster health (${endpoints})" >&2
    exit 1
  fi

  sleep "${SLEEP_SECONDS}"
  waited=$((waited + SLEEP_SECONDS))
done
