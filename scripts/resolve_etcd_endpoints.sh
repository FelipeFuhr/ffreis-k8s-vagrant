#!/usr/bin/env bash
set -euo pipefail

KUBE_NETWORK_PREFIX="${KUBE_NETWORK_PREFIX:-10.30.0}"
KUBE_ETCD_COUNT="${KUBE_ETCD_COUNT:-3}"
NODES_FILE="${NODES_FILE:-.vagrant-nodes.json}"

usage() {
  cat <<'EOF'
Usage:
  resolve_etcd_endpoints.sh [--format endpoints|nodes]

Output formats:
  endpoints   CSV like http://10.30.0.21:2379,http://10.30.0.22:2379
  nodes       Lines like: etcd1 10.30.0.21
EOF
}

format="endpoints"
if [[ "${1:-}" == "--format" ]]; then
  format="${2:-}"
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

emit_fallback_endpoints() {
  local endpoints="" i
  for i in $(seq 1 "${KUBE_ETCD_COUNT}"); do
    endpoints+="http://${KUBE_NETWORK_PREFIX}.$((20 + i)):2379,"
  done
  printf '%s\n' "${endpoints%,}"
}

emit_fallback_nodes() {
  local i
  for i in $(seq 1 "${KUBE_ETCD_COUNT}"); do
    printf 'etcd%s %s.%s\n' "${i}" "${KUBE_NETWORK_PREFIX}" "$((20 + i))"
  done
}

emit_from_nodes_json() {
  local out
  out="$(
    ruby -rjson -e '
      begin
        nodes = JSON.parse(File.read(ARGV[0]))
      rescue
        exit 2
      end
      etcd = nodes.select { |n| n["role"] == "etcd" && n["name"] && n["ip"] }
      exit 3 if etcd.empty?
      etcd.sort_by! { |n| n["name"].sub(/^etcd/, "").to_i }
      if ARGV[1] == "nodes"
        etcd.each { |n| puts "#{n["name"]} #{n["ip"]}" }
      else
        puts etcd.map { |n| "http://#{n["ip"]}:2379" }.join(",")
      end
    ' "${NODES_FILE}" "${format}" 2>/dev/null
  )" || return 1
  printf '%s\n' "${out}"
}

if [[ "${format}" != "endpoints" && "${format}" != "nodes" ]]; then
  echo "Invalid format: ${format}" >&2
  usage >&2
  exit 2
fi

if [[ "${format}" == "endpoints" && -n "${EXTERNAL_ETCD_ENDPOINTS:-}" ]]; then
  printf '%s\n' "${EXTERNAL_ETCD_ENDPOINTS}"
  exit 0
fi

if [[ -f "${NODES_FILE}" ]] && emit_from_nodes_json >/dev/null 2>&1; then
  emit_from_nodes_json
  exit 0
fi

if [[ "${format}" == "nodes" ]]; then
  emit_fallback_nodes
else
  emit_fallback_endpoints
fi
