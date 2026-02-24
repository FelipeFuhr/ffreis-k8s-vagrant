#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /vagrant/scripts/lib/script_init.sh ]]; then
  # shellcheck disable=SC1091
  source /vagrant/scripts/lib/script_init.sh
else
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/lib/script_init.sh"
fi
init_script_lib_dir "${BASH_SOURCE[0]}"
source_script_libs cluster_state

MAX_WAIT_SECONDS="${KUBE_JOIN_MAX_WAIT_SECONDS:-${MAX_WAIT_SECONDS:-900}}"
SLEEP_SECONDS="${KUBE_JOIN_POLL_SECONDS:-${SLEEP_SECONDS:-5}}"
node_name="$(hostname -s)"

if is_api_lb_node; then
  echo "api-lb is not a Kubernetes worker node, skipping join"
  exit 0
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Node already joined, skipping"
  exit 0
fi

wait_for_artifact /vagrant/.cluster/ready "${MAX_WAIT_SECONDS}" "${SLEEP_SECONDS}"
wait_for_artifact /vagrant/.cluster/join.sh "${MAX_WAIT_SECONDS}" "${SLEEP_SECONDS}"

load_join_values /vagrant/.cluster/join.sh
ENDPOINT="${JOIN_ENDPOINT}"
TOKEN="${JOIN_TOKEN}"
CA_HASH="${JOIN_CA_HASH}"

if [[ -z "${ENDPOINT}" || -z "${TOKEN}" || -z "${CA_HASH}" ]]; then
  echo "Invalid join command format in /vagrant/.cluster/join.sh" >&2
  echo "Raw line: $(head -n1 /vagrant/.cluster/join.sh)" >&2
  exit 1
fi

kubeadm join "${ENDPOINT}" --token "${TOKEN}" --discovery-token-ca-cert-hash "${CA_HASH}"
