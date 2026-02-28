#!/usr/bin/env bash
set -euo pipefail

name="${1:-}"
if [[ -z "${name}" ]]; then
  echo "Usage: $0 <node-name>" >&2
  exit 1
fi

inventory_file="${NODE_INVENTORY_FILE:-}"
if [[ -n "${inventory_file}" && -f "${inventory_file}" ]]; then
  ruby -ryaml -e '
inv = YAML.safe_load(File.read(ARGV[0]))
nodes = inv.is_a?(Hash) ? inv["nodes"] : inv
nodes ||= []
name = ARGV[1]
node = nodes.find { |n| n["name"] == name }
if node && node["ip"]
  puts node["ip"]
else
  exit 3
end
' "${inventory_file}" "${name}"
  exit 0
fi

if [[ "${name}" =~ ^cp([0-9]+)$ ]]; then
  echo "${KUBE_NETWORK_PREFIX:-10.30.0}.$((10 + ${BASH_REMATCH[1]}))"
  exit 0
fi
if [[ "${name}" =~ ^etcd([0-9]+)$ ]]; then
  echo "${KUBE_NETWORK_PREFIX:-10.30.0}.$((20 + ${BASH_REMATCH[1]}))"
  exit 0
fi
if [[ "${name}" =~ ^worker([0-9]+)$ ]]; then
  echo "${KUBE_NETWORK_PREFIX:-10.30.0}.$((100 + ${BASH_REMATCH[1]}))"
  exit 0
fi
if [[ "${name}" == "api-lb" ]]; then
  echo "${KUBE_API_LB_IP:-${KUBE_NETWORK_PREFIX:-10.30.0}.5}"
  exit 0
fi

echo "Unable to resolve IP for node '${name}'" >&2
exit 4
