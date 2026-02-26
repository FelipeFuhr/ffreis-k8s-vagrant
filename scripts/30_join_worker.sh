#!/usr/bin/env bash
set -euo pipefail

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
node_name="$(hostname -s)"

if [[ "${node_name}" == "api-lb" ]]; then
  echo "api-lb is not a Kubernetes worker node, skipping join"
  exit 0
fi

wait_for_artifact() {
  local path="$1"
  local waited report_interval total_steps step
  waited=0
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  if [[ "${report_interval}" -lt "${SLEEP_SECONDS}" ]]; then
    report_interval="${SLEEP_SECONDS}"
  fi
  total_steps=$(((MAX_WAIT_SECONDS + report_interval - 1) / report_interval))
  if [[ "${total_steps}" -lt 1 ]]; then
    total_steps=1
  fi

  while [[ ! -f "${path}" ]]; do
    if (( waited == 0 || waited % report_interval == 0 )); then
      step=$((waited / report_interval + 1))
      if [[ "${step}" -gt "${total_steps}" ]]; then
        step="${total_steps}"
      fi
      echo "Waiting for ${path} (${step}/${total_steps}, ${waited}s/${MAX_WAIT_SECONDS}s elapsed)" >&2
    fi

    if [[ -f /vagrant/.cluster/failed ]]; then
      echo "Control-plane bootstrap failed: $(cat /vagrant/.cluster/failed)" >&2
      echo "See host logs in .cluster/cp1-kubelet-error.log or .cluster/cp1-kubelet-init.log" >&2
      return 1
    fi

    if [[ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]]; then
      echo "Timed out waiting for ${path}" >&2
      return 1
    fi

    sleep "${SLEEP_SECONDS}"
    waited=$((waited + SLEEP_SECONDS))
  done
}

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Node already joined, skipping"
  exit 0
fi

wait_for_artifact /vagrant/.cluster/ready
wait_for_artifact /vagrant/.cluster/join.sh

JOIN_LINE="$(tr -d '\r' </vagrant/.cluster/join.sh | head -n1)"
ENDPOINT="$(awk '{print $3}' <<<"${JOIN_LINE}")"
TOKEN="$(awk '{for(i=1;i<=NF;i++) if($i=="--token") {print $(i+1); exit}}' <<<"${JOIN_LINE}")"
CA_HASH="$(awk '{for(i=1;i<=NF;i++) if($i=="--discovery-token-ca-cert-hash") {print $(i+1); exit}}' <<<"${JOIN_LINE}")"

if [[ -z "${ENDPOINT}" || -z "${TOKEN}" || -z "${CA_HASH}" ]]; then
  echo "Invalid join command format in /vagrant/.cluster/join.sh" >&2
  echo "Raw line: ${JOIN_LINE}" >&2
  exit 1
fi

kubeadm join "${ENDPOINT}" --token "${TOKEN}" --discovery-token-ca-cert-hash "${CA_HASH}"
