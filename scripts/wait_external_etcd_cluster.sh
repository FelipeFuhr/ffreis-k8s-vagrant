#!/usr/bin/env bash
set -euo pipefail

KUBE_NETWORK_PREFIX="${KUBE_NETWORK_PREFIX:-10.30.0}"
KUBE_ETCD_COUNT="${KUBE_ETCD_COUNT:-3}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-420}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"

vagrant_cmd() {
  ./scripts/vagrant_retry.sh vagrant "$@"
}

build_etcd_endpoints() {
  local endpoints="" i
  for i in $(seq 1 "${KUBE_ETCD_COUNT}"); do
    endpoints+="http://${KUBE_NETWORK_PREFIX}.$((20 + i)):2379,"
  done
  printf '%s' "${endpoints%,}"
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

endpoints="$(build_etcd_endpoints)"
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

  if vagrant_cmd ssh etcd1 -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint health >/dev/null 2>&1"; then
    health_ok=1
  fi

  member_count_raw="$(vagrant_cmd ssh etcd1 -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} member list | sed '/^$/d' | wc -l" 2>/dev/null || true)"
  member_count="$(tr -dc '0-9' <<<"${member_count_raw}")"
  [[ -n "${member_count}" ]] || member_count=0

  status_lines="$(vagrant_cmd ssh etcd1 -c "ETCDCTL_API=3 etcdctl --endpoints=${endpoints} endpoint status -w table | sed -n '/2379/p'" 2>/dev/null || true)"
  unique_ids="$(awk -F'|' '{id=$3; gsub(/ /,"",id); if(id!="") ids[id]=1} END{print (length(ids)+0)}' <<<"${status_lines}" 2>/dev/null || true)"
  leader_count="$(awk -F'|' '{leader=$6; gsub(/ /,"",leader); if(leader=="true") c++} END{print (c+0)}' <<<"${status_lines}" 2>/dev/null || true)"
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
