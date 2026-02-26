#!/usr/bin/env bash
set -euo pipefail

ETCD_NAME="${ETCD_NAME:?ETCD_NAME is required}"
ETCD_IP="${ETCD_IP:?ETCD_IP is required}"
ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER:?ETCD_INITIAL_CLUSTER is required}"
ETCD_VERSION="${ETCD_VERSION:-3.5.15}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"

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
  timeout=180
  interval=5
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  waited=0

  if [[ "${report_interval}" -lt "${interval}" ]]; then
    report_interval="${interval}"
  fi

  while true; do
    if ETCDCTL_API=3 etcdctl --endpoints="http://127.0.0.1:2379" endpoint health >/dev/null 2>&1; then
      return 0
    fi

    if (( waited == 0 || waited % report_interval == 0 )); then
      log_wait_progress "Waiting for local etcd readiness (${ETCD_NAME})" "${waited}" "${timeout}" "${report_interval}"
    fi

    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for local etcd readiness (${ETCD_NAME})" >&2
      return 1
    fi

    sleep "${interval}"
    waited=$((waited + interval))
  done
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -o APT::Update::Error-Mode=any
apt-get install -y curl tar ca-certificates

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

cat >/etc/systemd/system/etcd.service <<CFG
[Unit]
Description=etcd key-value store
Documentation=https://etcd.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
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
  --initial-cluster-state=new \
  --initial-cluster-token=k8s-vagrant-external-etcd
Restart=always
RestartSec=5
LimitNOFILE=40000

[Install]
WantedBy=multi-user.target
CFG

systemctl daemon-reload
systemctl enable etcd
systemctl stop etcd >/dev/null 2>&1 || true
# Keep provisioning deterministic: wipe stale local etcd state before (re)bootstrap.
rm -rf /var/lib/etcd/default/*
chown -R etcd:etcd /var/lib/etcd
systemctl restart etcd

wait_for_local_etcd
