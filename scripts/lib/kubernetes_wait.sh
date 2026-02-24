#!/usr/bin/env bash

wait_for_ip() {
  local wanted_ip="$1"
  local timeout="${2:-180}"
  local waited=0

  until ip -o -4 addr show | awk '{print $4}' | grep -q "^${wanted_ip}/"; do
    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for ${wanted_ip} on this node" >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

wait_for_apiserver() {
  local kubeconfig_path="$1"
  local timeout="${2:-420}"
  local waited=0

  until kubectl --kubeconfig "${kubeconfig_path}" get --raw=/readyz >/dev/null 2>&1; do
    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for Kubernetes API readiness" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}
