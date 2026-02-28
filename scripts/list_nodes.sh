#!/usr/bin/env bash
set -euo pipefail

role="${1:-}"
if [[ -z "${role}" ]]; then
  echo "Usage: $0 control-plane|worker|etcd|api-lb" >&2
  exit 1
fi

inventory_file="${NODE_INVENTORY_FILE:-}"
if [[ -n "${inventory_file}" && -f "${inventory_file}" ]]; then
  ruby -ryaml -e '
inv = YAML.safe_load(File.read(ARGV[0]))
nodes = inv.is_a?(Hash) ? inv["nodes"] : inv
nodes ||= []
role = ARGV[1]
nodes.each do |n|
  puts n["name"] if n["role"] == role
end
' "${inventory_file}" "${role}"
  exit 0
fi

case "${role}" in
  control-plane)
    for i in $(seq 1 "${KUBE_CP_COUNT:-1}"); do echo "cp${i}"; done
    ;;
  worker)
    for i in $(seq 1 "${KUBE_WORKER_COUNT:-0}"); do echo "worker${i}"; done
    ;;
  etcd)
    for i in $(seq 1 "${KUBE_ETCD_COUNT:-3}"); do echo "etcd${i}"; done
    ;;
  api-lb)
    if [[ "${KUBE_API_LB_ENABLED:-true}" == "true" && "${KUBE_CP_COUNT:-1}" -gt 1 ]]; then
      echo "api-lb"
    fi
    ;;
  *)
    echo "Unsupported role: ${role}" >&2
    exit 2
    ;;
esac
