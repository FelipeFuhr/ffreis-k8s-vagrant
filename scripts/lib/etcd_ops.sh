#!/usr/bin/env bash

etcdctl_cp1_exec() {
  local kubeconfig_path="$1"
  local etcd_subcommand="$2"

  kubectl --kubeconfig "${kubeconfig_path}" -n kube-system exec etcd-cp1 -- sh -lc \
    "ETCDCTL_API=3 etcdctl \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/peer.crt \
      --key=/etc/kubernetes/pki/etcd/peer.key \
      ${etcd_subcommand}"
}

cleanup_stale_node_with_retries() {
  local kubeconfig_path="$1"
  local node_name="$2"
  local max_tries="${3:-5}"
  local tries=0

  if [[ ! -f "${kubeconfig_path}" ]]; then
    return 0
  fi

  while [[ "${tries}" -lt "${max_tries}" ]]; do
    if kubectl --kubeconfig "${kubeconfig_path}" get node "${node_name}" >/dev/null 2>&1; then
      echo "Deleting stale node object '${node_name}' before retry" >&2
      kubectl --kubeconfig "${kubeconfig_path}" delete node "${node_name}" --wait=true || true
      return 0
    fi
    tries=$((tries + 1))
    sleep 3
  done
}

cleanup_stale_etcd_member_by_node() {
  local kubeconfig_path="$1"
  local node_name="$2"
  local member_id

  if [[ ! -f "${kubeconfig_path}" ]]; then
    return 0
  fi

  member_id="$(
    etcdctl_cp1_exec "${kubeconfig_path}" \
      "member list | awk -F', ' '/, ${node_name},/ {print \$1; exit}'" 2>/dev/null || true
  )"

  if [[ -n "${member_id}" ]]; then
    echo "Removing stale etcd member '${node_name}' (${member_id}) before retry" >&2
    etcdctl_cp1_exec "${kubeconfig_path}" "member remove ${member_id}" >/dev/null 2>&1 || true
  fi
}

cleanup_stale_etcd_learners() {
  local kubeconfig_path="$1"
  local learner_ids lid

  if [[ ! -f "${kubeconfig_path}" ]]; then
    return 0
  fi

  # Handle both etcdctl formats:
  # - "... isLearner=true"
  # - trailing boolean column "... , true"
  learner_ids="$(
    etcdctl_cp1_exec "${kubeconfig_path}" \
      "member list | awk -F', ' '{
        if (\$0 ~ /isLearner=true/ || \$NF == \"true\") print \$1
      }'" 2>/dev/null || true
  )"

  if [[ -z "${learner_ids}" ]]; then
    return 0
  fi

  while IFS= read -r lid; do
    [[ -z "${lid}" ]] && continue
    echo "Removing stale etcd learner member (${lid}) before retry" >&2
    etcdctl_cp1_exec "${kubeconfig_path}" "member remove ${lid}" >/dev/null 2>&1 || true
  done <<<"${learner_ids}"
}
