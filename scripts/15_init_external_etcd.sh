#!/usr/bin/env bash
set -euo pipefail

ETCD_NAME="${ETCD_NAME:?ETCD_NAME is required}"
ETCD_IP="${ETCD_IP:?ETCD_IP is required}"
ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER:?ETCD_INITIAL_CLUSTER is required}"
ETCD_VERSION="${ETCD_VERSION:-3.5.15}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
ETCD_REINIT_ON_PROVISION="${ETCD_REINIT_ON_PROVISION:-true}"
ETCD_AUTO_RECOVER_ON_FAILURE="${ETCD_AUTO_RECOVER_ON_FAILURE:-true}"

if [[ -f /vagrant/scripts/lib_apt.sh ]]; then
  # shellcheck source=/vagrant/scripts/lib_apt.sh disable=SC1091
  source /vagrant/scripts/lib_apt.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib_apt.sh disable=SC1091
  source "${SCRIPT_DIR}/lib_apt.sh"
fi

retry_download() {
  local url="$1"
  local out_file="$2"
  local attempts="${3:-8}"
  local n=1
  until curl -fL --connect-timeout 15 --max-time 180 --retry 5 --retry-delay 2 --retry-all-errors "${url}" -o "${out_file}"; do
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    n=$((n + 1))
    sleep 4
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

wait_for_local_etcd() {
  local timeout interval report_interval waited
  timeout="${ETCD_LOCAL_START_TIMEOUT_SECONDS:-60}"
  interval=3
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  waited=0

  if [[ "${report_interval}" -lt "${interval}" ]]; then
    report_interval="${interval}"
  fi

  while true; do
    # Per-node readiness must not depend on quorum. Full quorum is validated
    # later by scripts/wait_external_etcd_cluster.sh after all etcd nodes are up.
    if systemctl is-active --quiet etcd && ss -lnt '( sport = :2379 )' | grep -q ':2379'; then
      return 0
    fi

    if (( waited == 0 || waited % report_interval == 0 )); then
      log_wait_progress "Waiting for local etcd readiness (${ETCD_NAME})" "${waited}" "${timeout}" "${report_interval}"
    fi

    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for local etcd readiness (${ETCD_NAME})" >&2
      systemctl status etcd --no-pager -l || true
      journalctl -u etcd --no-pager -n 120 || true
      return 1
    fi

    sleep "${interval}"
    waited=$((waited + interval))
  done
}

export DEBIAN_FRONTEND=noninteractive
install_missing_no_upgrade curl tar ca-certificates

if ! id -u etcd >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/etcd --shell /usr/sbin/nologin etcd
fi

installed_version="$(etcd --version 2>/dev/null | awk '/^etcd Version:/ {print $3}' || true)"
if [[ "${installed_version}" != "${ETCD_VERSION}" || ! -x /usr/local/bin/etcdctl ]]; then
  tmp_dir="$(mktemp -d)"
  archive="etcd-v${ETCD_VERSION}-linux-amd64.tar.gz"
  download_url="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${archive}"
  retry_download "${download_url}" "${tmp_dir}/${archive}" 8
  tar -xzf "${tmp_dir}/${archive}" -C "${tmp_dir}"
  install -m 0755 "${tmp_dir}/etcd-v${ETCD_VERSION}-linux-amd64/etcd" /usr/local/bin/etcd
  install -m 0755 "${tmp_dir}/etcd-v${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/etcdctl
  rm -rf "${tmp_dir}"
fi

install -d -m 0700 -o etcd -g etcd /var/lib/etcd/default

reset_etcd_data_dir() {
  systemctl stop etcd >/dev/null 2>&1 || true
  rm -rf /var/lib/etcd/default
  install -d -m 0700 -o etcd -g etcd /var/lib/etcd/default
}

recent_etcd_bootstrap_error() {
  journalctl -u etcd --no-pager -n 400 2>/dev/null | grep -E -q "has already been bootstrapped|server has been already initialized"
}

render_etcd_unit() {
  local cluster_state="$1"
  cat >/etc/systemd/system/etcd.service <<CFG
[Unit]
Description=etcd key-value store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd \
  --name=${ETCD_NAME} \
  --data-dir=/var/lib/etcd/default \
  --listen-client-urls=http://${ETCD_IP}:2379,http://127.0.0.1:2379 \
  --advertise-client-urls=http://${ETCD_IP}:2379 \
  --listen-peer-urls=http://${ETCD_IP}:2380 \
  --initial-advertise-peer-urls=http://${ETCD_IP}:2380 \
  --initial-cluster=${ETCD_INITIAL_CLUSTER} \
  --initial-cluster-state=${cluster_state} \
  --initial-cluster-token=k8s-vagrant-external-etcd
Restart=always
RestartSec=5
TimeoutStartSec=120
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
CFG
}

if [[ "${ETCD_REINIT_ON_PROVISION}" == "true" ]]; then
  reset_etcd_data_dir
fi

cluster_state="new"
if [[ -d /var/lib/etcd/default/member ]]; then
  cluster_state="existing"
fi

render_etcd_unit "${cluster_state}"
systemctl daemon-reload
systemctl enable etcd
systemctl stop etcd >/dev/null 2>&1 || true
chown -R etcd:etcd /var/lib/etcd
systemctl restart etcd

etcd_ready=0
if wait_for_local_etcd; then
  etcd_ready=1
fi

if [[ "${etcd_ready}" -eq 0 ]]; then
  if [[ "${ETCD_AUTO_RECOVER_ON_FAILURE}" == "true" ]]; then
    echo "Local etcd failed first start on ${ETCD_NAME}; attempting one-time recovery restart" >&2
    if [[ -d /var/lib/etcd/default/member ]] || recent_etcd_bootstrap_error; then
      echo "Detected existing member state on ${ETCD_NAME}; retrying with initial-cluster-state=existing" >&2
      cluster_state="existing"
      render_etcd_unit "${cluster_state}"
      systemctl daemon-reload
      systemctl restart etcd || true
    else
      echo "No usable member state detected on ${ETCD_NAME}; reinitializing local etcd data dir" >&2
      reset_etcd_data_dir
      cluster_state="new"
      render_etcd_unit "${cluster_state}"
      systemctl daemon-reload
      systemctl restart etcd || true
    fi
    if wait_for_local_etcd; then
      etcd_ready=1
    fi
  fi
fi

if [[ "${etcd_ready}" -eq 0 ]]; then
  echo "Continuing provisioning for ${ETCD_NAME}; cluster-wide etcd gate will validate quorum before cp boot." >&2
fi
