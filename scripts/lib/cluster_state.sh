#!/usr/bin/env bash

is_api_lb_node() {
  [[ "$(hostname -s)" == "api-lb" ]]
}

wait_for_artifact() {
  local path="$1"
  local max_wait_seconds="${2:-900}"
  local sleep_seconds="${3:-5}"
  local waited=0

  while [[ ! -f "${path}" ]]; do
    if [[ -f /vagrant/.cluster/failed ]]; then
      echo "Control-plane bootstrap failed: $(cat /vagrant/.cluster/failed)" >&2
      echo "See host logs in .cluster/cp1-kubelet-error.log or .cluster/cp1-kubelet-init.log" >&2
      return 1
    fi

    if [[ "${waited}" -ge "${max_wait_seconds}" ]]; then
      echo "Timed out waiting for ${path}" >&2
      return 1
    fi

    sleep "${sleep_seconds}"
    waited=$((waited + sleep_seconds))
  done
}

load_join_values() {
  local join_file="$1"
  local join_line
  join_line="$(tr -d '\r' <"${join_file}" | head -n1)"

  JOIN_ENDPOINT="$(awk '{print $3}' <<<"${join_line}")"
  JOIN_TOKEN="$(awk '{for(i=1;i<=NF;i++) if($i=="--token") {print $(i+1); exit}}' <<<"${join_line}")"
  JOIN_CA_HASH="$(awk '{for(i=1;i<=NF;i++) if($i=="--discovery-token-ca-cert-hash") {print $(i+1); exit}}' <<<"${join_line}")"
}
