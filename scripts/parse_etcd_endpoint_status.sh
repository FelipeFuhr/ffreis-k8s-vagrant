#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  parse_etcd_endpoint_status.sh [--field unique_ids|leaders] [json_file]
  cat status.json | parse_etcd_endpoint_status.sh
EOF
}

field=""
json_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --field)
      field="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      json_file="$1"
      shift
      ;;
  esac
done

if [[ -n "${json_file}" ]]; then
  status_json="$(cat "${json_file}")"
else
  status_json="$(cat)"
fi

if [[ -z "${status_json}" ]]; then
  unique_ids=0
  leader_count=0
else
  ids_new="$(printf '%s' "${status_json}" | grep -o '"ID":[0-9]*' | cut -d: -f2 || true)"
  ids_old="$(printf '%s' "${status_json}" | grep -o '"member_id":[0-9]*' | cut -d: -f2 || true)"
  unique_ids="$(printf '%s\n%s\n' "${ids_new}" "${ids_old}" | sed '/^$/d' | sort -u | wc -l | tr -dc '0-9' || true)"
  [[ -n "${unique_ids}" ]] || unique_ids=0

  leader_count="$(printf '%s' "${status_json}" | grep -o '"IsLeader":[^,}]*' | grep -c 'true' || true)"
  if [[ "${leader_count}" -eq 0 ]]; then
    leader_count="$(printf '%s' "${status_json}" \
      | grep -o '"member_id":[0-9]*\|"leader":[0-9]*' \
      | paste - - \
      | awk -F'[:,"]+' '$3==$5 {c++} END{print c+0}' || true)"
  fi
  [[ -n "${leader_count}" ]] || leader_count=0
fi

case "${field}" in
  "")
    echo "unique_ids=${unique_ids} leaders=${leader_count}"
    ;;
  unique_ids)
    echo "${unique_ids}"
    ;;
  leaders)
    echo "${leader_count}"
    ;;
  *)
    echo "Invalid field: ${field}" >&2
    usage >&2
    exit 2
    ;;
esac
