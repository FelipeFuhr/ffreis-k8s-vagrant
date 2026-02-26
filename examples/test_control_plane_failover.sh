#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f config/cluster.env ]]; then
  # shellcheck disable=SC1091
  source config/cluster.env
fi

poll_seconds="${FAILOVER_POLL_SECONDS:-5}"
failover_timeout="${FAILOVER_TIMEOUT_SECONDS:-180}"
node_ready_timeout="${NODE_READY_TIMEOUT_SECONDS:-300}"
target_node="${1:-}"

retry() {
  ./scripts/vagrant_retry.sh "$@"
}

discover_cp_nodes() {
  local kube_nodes
  local cp_count_fallback i
  CP_NODES=()

  kube_nodes="$(retry vagrant ssh cp1 -c \
    "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -l node-role.kubernetes.io/control-plane -o name 2>/dev/null" \
    | tr -d '\r' || true)"

  if [[ -n "${kube_nodes}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      CP_NODES+=("${line#node/}")
    done <<<"${kube_nodes}"
    return 0
  fi

  cp_count_fallback="${KUBE_CP_COUNT:-1}"
  for i in $(seq 1 "${cp_count_fallback}"); do
    CP_NODES+=("cp${i}")
  done
}

node_from_holder() {
  local holder="$1"
  if [[ "${holder}" == *"_"* ]]; then
    printf '%s\n' "${holder%%_*}"
  else
    printf '%s\n' "${holder}"
  fi
}

choose_helper_node() {
  local exclude="$1"
  local node
  for node in "${CP_NODES[@]}"; do
    if [[ "${node}" != "${exclude}" ]]; then
      printf '%s\n' "${node}"
      return 0
    fi
  done
  return 1
}

lease_holder() {
  local helper="$1"
  local lease="$2"
  retry vagrant ssh "${helper}" -c \
    "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get lease ${lease} -o jsonpath='{.spec.holderIdentity}'" \
    | tr -d '\r'
}

wait_for_lease_not_on_node() {
  local helper="$1"
  local lease="$2"
  local forbidden_node="$3"
  local timeout="$4"
  local waited holder holder_node
  waited=0

  while [[ "${waited}" -le "${timeout}" ]]; do
    holder="$(lease_holder "${helper}" "${lease}")"
    holder_node="$(node_from_holder "${holder}")"
    if [[ "${holder_node}" != "${forbidden_node}" ]]; then
      printf '%s\n' "${holder}"
      return 0
    fi
    sleep "${poll_seconds}"
    waited=$((waited + poll_seconds))
  done

  return 1
}

wait_for_node_ready() {
  local helper="$1"
  local node="$2"
  local timeout="$3"
  local waited ready
  waited=0

  while [[ "${waited}" -le "${timeout}" ]]; do
    ready="$(retry vagrant ssh "${helper}" -c \
      "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node ${node} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" \
      | tr -d '\r' || true)"
    if [[ "${ready}" == "True" ]]; then
      return 0
    fi
    sleep "${poll_seconds}"
    waited=$((waited + poll_seconds))
  done

  return 1
}

discover_cp_nodes
if [[ "${#CP_NODES[@]}" -lt 2 ]]; then
  echo "Need at least 2 control planes to run failover test (detected=${#CP_NODES[@]})."
  exit 1
fi

bootstrap_helper="${CP_NODES[0]}"
controller_holder="$(lease_holder "${bootstrap_helper}" "kube-controller-manager")"
controller_node="$(node_from_holder "${controller_holder}")"
scheduler_holder="$(lease_holder "${bootstrap_helper}" "kube-scheduler")"
scheduler_node="$(node_from_holder "${scheduler_holder}")"

if [[ -z "${target_node}" ]]; then
  target_node="${controller_node}"
fi

if [[ ! "${target_node}" =~ ^cp[0-9]+$ ]]; then
  echo "Invalid target control-plane node: ${target_node}"
  exit 1
fi
if [[ " ${CP_NODES[*]} " != *" ${target_node} "* ]]; then
  echo "Target node ${target_node} is not a detected control-plane node (${CP_NODES[*]})."
  exit 1
fi

helper_node="$(choose_helper_node "${target_node}")"

echo "Initial leaders:"
echo "- kube-controller-manager: ${controller_holder}"
echo "- kube-scheduler:          ${scheduler_holder}"
echo "Failover target: ${target_node}"
echo "Helper node: ${helper_node}"

echo "Halting ${target_node}..."
retry vagrant halt "${target_node}" --force

if [[ "${controller_node}" == "${target_node}" ]]; then
  new_controller_holder="$(wait_for_lease_not_on_node "${helper_node}" "kube-controller-manager" "${target_node}" "${failover_timeout}")" || {
    echo "Timed out waiting for kube-controller-manager lease failover away from ${target_node}"
    exit 1
  }
  echo "Controller-manager failover observed: ${new_controller_holder}"
else
  echo "Controller-manager leader was not on ${target_node}; skipping strict lease-failover assertion."
fi

if [[ "${scheduler_node}" == "${target_node}" ]]; then
  new_scheduler_holder="$(wait_for_lease_not_on_node "${helper_node}" "kube-scheduler" "${target_node}" "${failover_timeout}")" || {
    echo "Timed out waiting for kube-scheduler lease failover away from ${target_node}"
    exit 1
  }
  echo "Scheduler failover observed: ${new_scheduler_holder}"
else
  echo "Scheduler leader was not on ${target_node}; skipping strict lease-failover assertion."
fi

echo "Bringing ${target_node} back up..."
retry vagrant up "${target_node}" --provider "${KUBE_PROVIDER:-libvirt}" --no-provision

wait_for_node_ready "${helper_node}" "${target_node}" "${node_ready_timeout}" || {
  echo "Timed out waiting for ${target_node} to return Ready"
  exit 1
}

echo "Control-plane failover test passed: ${target_node} down/up with control-plane leadership maintained."
