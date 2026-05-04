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
source_script_libs cluster_state retry etcd_ops join_retry error
setup_error_trap "$(basename "${BASH_SOURCE[0]}")"

MAX_WAIT_SECONDS="${KUBE_JOIN_MAX_WAIT_SECONDS:-${MAX_WAIT_SECONDS:-900}}"
SLEEP_SECONDS="${KUBE_JOIN_POLL_SECONDS:-${SLEEP_SECONDS:-5}}"
CP_JOIN_RETRY_ATTEMPTS="${KUBE_CP_JOIN_RETRY_ATTEMPTS:-5}"
CP_JOIN_RETRY_SLEEP_SECONDS="${KUBE_CP_JOIN_RETRY_SLEEP_SECONDS:-15}"
CP_JOIN_RETRY_BACKOFF_FACTOR="${KUBE_CP_JOIN_RETRY_BACKOFF_FACTOR:-2}"
CP_JOIN_RETRY_MAX_SLEEP_SECONDS="${KUBE_CP_JOIN_RETRY_MAX_SLEEP_SECONDS:-120}"
CP_JOIN_RETRY_MAX_TOTAL_SECONDS="${KUBE_CP_JOIN_RETRY_MAX_TOTAL_SECONDS:-1200}"
KUBECONFIG_PATH="/vagrant/.cluster/admin.conf"
node_name="$(hostname -s)"

if is_api_lb_node; then
  echo "api-lb is not a Kubernetes control-plane node, skipping join"
  exit 0
fi

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  echo "Node already joined, skipping"
  exit 0
fi

prejoin_peer_connectivity_check() {
  local current_idx peer_idx peer_name peer_ip
  if [[ ! "${node_name}" =~ ^cp([0-9]+)$ ]]; then
    return 0
  fi
  current_idx="${BASH_REMATCH[1]}"
  if [[ "${current_idx}" -le 1 ]]; then
    return 0
  fi

  for peer_idx in $(seq 1 $((current_idx - 1))); do
    peer_name="cp${peer_idx}"
    peer_ip="$(getent hosts "${peer_name}" | awk '{print $1; exit}' || true)"
    if [[ -z "${peer_ip}" ]]; then
      echo "Pre-join network check failed: cannot resolve ${peer_name}" >&2
      echo "Ensure /etc/hosts contains cluster node mappings." >&2
      return 1
    fi

    # etcd peer traffic must be reachable before attempting join.
    if ! retry 6 timeout 5 bash -c "echo > /dev/tcp/${peer_ip}/2380"; then
      echo "Pre-join network check failed: cannot reach ${peer_name} (${peer_ip}):2380" >&2
      return 1
    fi
  done
}

wait_for_artifact /vagrant/.cluster/ready "${MAX_WAIT_SECONDS}" "${SLEEP_SECONDS}"
wait_for_artifact /vagrant/.cluster/join.sh "${MAX_WAIT_SECONDS}" "${SLEEP_SECONDS}"
wait_for_artifact /vagrant/.cluster/certificate-key "${MAX_WAIT_SECONDS}" "${SLEEP_SECONDS}"
prejoin_peer_connectivity_check

load_join_values /vagrant/.cluster/join.sh
ENDPOINT="${JOIN_ENDPOINT}"
TOKEN="${JOIN_TOKEN}"
CA_HASH="${JOIN_CA_HASH}"
CERT_KEY="$(tr -d '\r' </vagrant/.cluster/certificate-key | head -n1)"

if [[ -z "${ENDPOINT}" || -z "${TOKEN}" || -z "${CA_HASH}" || -z "${CERT_KEY}" ]]; then
  echo "Invalid join/certificate data in /vagrant/.cluster" >&2
  exit 1
fi

join_once() {
  local warn_show_limit warn_report_interval warn_report_every
  warn_show_limit="${KUBE_CP_JOIN_WARN_SHOW_LIMIT:-${ETCD_WARN_SHOW_LIMIT:-2}}"
  warn_report_interval="${KUBE_CP_JOIN_WARN_REPORT_INTERVAL_SECONDS:-${ETCD_WARN_REPORT_INTERVAL_SECONDS:-120}}"
  warn_report_every="${KUBE_CP_JOIN_WARN_REPORT_EVERY:-250}"

  kubeadm join "${ENDPOINT}" \
    --token "${TOKEN}" \
    --discovery-token-ca-cert-hash "${CA_HASH}" \
    --control-plane \
    --certificate-key "${CERT_KEY}" 2>&1 \
    | awk -v limit="${warn_show_limit}" -v interval="${warn_report_interval}" -v report_every="${warn_report_every}" '
      BEGIN {
        shown = 0
        suppressed = 0
        last_report = systime()
        suppression_noted = 0
        pattern_sync = "can only promote a learner member which is in sync with leader"
        pattern_too_many = "too many learner members in cluster"
      }
      {
        if (index($0, pattern_sync) > 0 || index($0, pattern_too_many) > 0) {
          if (shown < limit) {
            print
            shown++
            next
          }

          suppressed++
          if (suppression_noted == 0) {
            print "[cp-join] throttling repeated etcd learner warnings..."
            fflush()
            suppression_noted = 1
          }
          now = systime()
          if ((suppressed % report_every) == 0 || (now - last_report) >= interval) {
            printf("[cp-join] etcd learner warnings suppressed: %d\n", suppressed)
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

on_join_failure() {
  local attempt="$1"
  local elapsed_seconds="$2"
  local retry_sleep_seconds

  echo "Control-plane join attempt ${attempt} failed; resetting node and retrying" >&2
  cleanup_stale_node_with_retries "${KUBECONFIG_PATH}" "${node_name}" 5
  cleanup_stale_etcd_member_by_node "${KUBECONFIG_PATH}" "${node_name}"
  cleanup_stale_etcd_learners "${KUBECONFIG_PATH}"
  kubeadm reset -f || true
  systemctl restart containerd kubelet || true
  retry_sleep_seconds="$(compute_backoff_sleep_seconds "${attempt}" "${CP_JOIN_RETRY_SLEEP_SECONDS}" "${CP_JOIN_RETRY_BACKOFF_FACTOR}" "${CP_JOIN_RETRY_MAX_SLEEP_SECONDS}")"
  echo "Control-plane join backoff: sleeping ${retry_sleep_seconds}s (attempt ${attempt}, elapsed ${elapsed_seconds}s)" >&2
}

if ! run_with_backoff_retry_loop \
  "${CP_JOIN_RETRY_ATTEMPTS}" \
  "${CP_JOIN_RETRY_SLEEP_SECONDS}" \
  "${CP_JOIN_RETRY_BACKOFF_FACTOR}" \
  "${CP_JOIN_RETRY_MAX_SLEEP_SECONDS}" \
  "${CP_JOIN_RETRY_MAX_TOTAL_SECONDS}" \
  join_once \
  on_join_failure; then
  exit 1
fi
