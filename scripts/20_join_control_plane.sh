#!/usr/bin/env bash
set -euo pipefail

MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
SLEEP_SECONDS="${SLEEP_SECONDS:-5}"
CP_JOIN_MAX_ATTEMPTS="${CP_JOIN_MAX_ATTEMPTS:-8}"
CP_JOIN_BASE_BACKOFF_SECONDS="${CP_JOIN_BASE_BACKOFF_SECONDS:-60}"
CP_JOIN_MAX_BACKOFF_SECONDS="${CP_JOIN_MAX_BACKOFF_SECONDS:-240}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
EXTERNAL_ETCD_ENDPOINTS="${EXTERNAL_ETCD_ENDPOINTS:-}"
node_name="$(hostname -s)"

if [[ "${node_name}" == "api-lb" ]]; then
  echo "api-lb is not a Kubernetes control-plane node, skipping join"
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

log_wait_progress() {
  local label="$1"
  local waited="$2"
  local timeout="$3"
  local report_interval="$4"
  local step total_steps

  total_steps=$(((timeout + report_interval - 1) / report_interval))
  if [[ "${total_steps}" -lt 1 ]]; then
    total_steps=1
  fi

  step=$((waited / report_interval + 1))
  if [[ "${step}" -gt "${total_steps}" ]]; then
    step="${total_steps}"
  fi

  echo "${label} (${step}/${total_steps}, ${waited}s/${timeout}s elapsed)" >&2
}

wait_for_external_etcd() {
  local timeout interval report_interval waited endpoint healthy_count total_count
  timeout=420
  interval=5
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  waited=0

  if [[ -z "${EXTERNAL_ETCD_ENDPOINTS}" ]]; then
    echo "EXTERNAL_ETCD_ENDPOINTS is required for control-plane join" >&2
    return 1
  fi

  if [[ "${report_interval}" -lt "${interval}" ]]; then
    report_interval="${interval}"
  fi

  while true; do
    healthy_count=0
    total_count=0
    IFS=',' read -r -a endpoints <<<"${EXTERNAL_ETCD_ENDPOINTS}"
    for endpoint in "${endpoints[@]}"; do
      endpoint="${endpoint%/}"
      total_count=$((total_count + 1))
      if curl -fsS --connect-timeout 2 --max-time 3 "${endpoint}/health" >/dev/null 2>&1; then
        healthy_count=$((healthy_count + 1))
      fi
    done

    if [[ "${healthy_count}" -eq "${total_count}" && "${total_count}" -gt 0 ]]; then
      return 0
    fi

    if (( waited == 0 || waited % report_interval == 0 )); then
      log_wait_progress "Waiting for external etcd health (${healthy_count}/${total_count} endpoints)" "${waited}" "${timeout}" "${report_interval}"
    fi

    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for external etcd endpoints: ${EXTERNAL_ETCD_ENDPOINTS}" >&2
      return 1
    fi

    sleep "${interval}"
    waited=$((waited + interval))
  done
}

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Node already joined, skipping"
  exit 0
fi

wait_for_artifact /vagrant/.cluster/ready
wait_for_artifact /vagrant/.cluster/join.sh
wait_for_artifact /vagrant/.cluster/certificate-key
wait_for_artifact /vagrant/.cluster/pki-control-plane.tgz

JOIN_LINE="$(tr -d '\r' </vagrant/.cluster/join.sh | head -n1)"
ENDPOINT="$(awk '{print $3}' <<<"${JOIN_LINE}")"
TOKEN="$(awk '{for(i=1;i<=NF;i++) if($i=="--token") {print $(i+1); exit}}' <<<"${JOIN_LINE}")"
CA_HASH="$(awk '{for(i=1;i<=NF;i++) if($i=="--discovery-token-ca-cert-hash") {print $(i+1); exit}}' <<<"${JOIN_LINE}")"

if [[ -z "${ENDPOINT}" || -z "${TOKEN}" || -z "${CA_HASH}" ]]; then
  echo "Invalid join/certificate data in /vagrant/.cluster" >&2
  exit 1
fi

prepare_control_plane_pki() {
  if [[ -f /etc/kubernetes/pki/ca.crt && -f /etc/kubernetes/pki/ca.key ]]; then
    return 0
  fi

  mkdir -p /etc/kubernetes
  tar -C /etc/kubernetes -xzf /vagrant/.cluster/pki-control-plane.tgz
}

join_once() {
  local warn_show_limit warn_report_interval
  warn_show_limit="${ETCD_WARN_SHOW_LIMIT:-1}"
  warn_report_interval="${ETCD_WARN_REPORT_INTERVAL_SECONDS:-90}"

  prepare_control_plane_pki

  kubeadm join "${ENDPOINT}" \
    --token "${TOKEN}" \
    --discovery-token-ca-cert-hash "${CA_HASH}" \
    --control-plane \
    --skip-phases=control-plane-prepare/download-certs 2>&1 \
    | awk -v limit="${warn_show_limit}" -v interval="${warn_report_interval}" '
      BEGIN {
        shown = 0
        suppressed = 0
        last_report = systime()
        pattern = "can only promote a learner member which is in sync with leader"
      }
      {
        if (index($0, pattern) > 0) {
          if (shown < limit) {
            print
            shown++
            next
          }

          suppressed++
          now = systime()
          if ((now - last_report) >= interval) {
            printf("[cp-join] throttled etcd learner warnings: %d suppressed so far\n", suppressed)
            fflush()
            last_report = now
          }
          next
        }

        print
      }
      END {
        if (suppressed > 0) {
          printf("[cp-join] throttled etcd learner warnings total: %d\n", suppressed)
        }
      }
    '
}

cleanup_stale_node() {
  local kubeconfig_path="/vagrant/.cluster/admin.conf"
  if [[ ! -f "${kubeconfig_path}" ]]; then
    return 0
  fi

  if kubectl --kubeconfig "${kubeconfig_path}" get node "${node_name}" >/dev/null 2>&1; then
    echo "Deleting stale node object '${node_name}' before retry" >&2
    kubectl --request-timeout=30s --kubeconfig "${kubeconfig_path}" delete node "${node_name}" --wait=true >/dev/null 2>&1 || true
  fi
}

attempt=1
max_attempts="${CP_JOIN_MAX_ATTEMPTS}"
while true; do
  wait_for_external_etcd

  if join_once; then
    break
  fi

  if [[ "${attempt}" -ge "${max_attempts}" ]]; then
    echo "kubeadm control-plane join failed after ${max_attempts} attempts" >&2
    exit 1
  fi

  echo "Control-plane join attempt ${attempt} failed; resetting node and retrying" >&2
  cleanup_stale_node
  kubeadm reset -f || true
  systemctl restart containerd kubelet || true
  backoff_seconds=$((CP_JOIN_BASE_BACKOFF_SECONDS * attempt))
  if [[ "${backoff_seconds}" -gt "${CP_JOIN_MAX_BACKOFF_SECONDS}" ]]; then
    backoff_seconds="${CP_JOIN_MAX_BACKOFF_SECONDS}"
  fi
  echo "Waiting ${backoff_seconds}s before next control-plane join attempt (retry $((attempt + 1))/${max_attempts})" >&2
  sleep "${backoff_seconds}"
  attempt=$((attempt + 1))
done
