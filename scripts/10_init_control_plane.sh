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
source_script_libs kubernetes_wait

CP1_IP="${CP1_IP:-10.30.0.11}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${CP1_IP}:6443}"
CONTROL_PLANE_ENDPOINT_HOST="${CONTROL_PLANE_ENDPOINT_HOST:-cp1}"
KUBE_POD_CIDR="${KUBE_POD_CIDR:-10.244.0.0/16}"
KUBE_SERVICE_CIDR="${KUBE_SERVICE_CIDR:-10.96.0.0/12}"
KUBE_CNI="${KUBE_CNI:-flannel}"
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CNI_MANIFEST_FLANNEL="${KUBE_CNI_MANIFEST_FLANNEL:-https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml}"
KUBE_CNI_MANIFEST_CALICO="${KUBE_CNI_MANIFEST_CALICO:-https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml}"
KUBE_CNI_MANIFEST_CILIUM="${KUBE_CNI_MANIFEST_CILIUM:-https://raw.githubusercontent.com/cilium/cilium/v1.16.5/install/kubernetes/quick-install.yaml}"
KUBEADM_LOG="/vagrant/.cluster/cp1-kubeadm.log"
CP1_WAIT_IP_TIMEOUT_SECONDS="${CP1_WAIT_IP_TIMEOUT_SECONDS:-600}"
CP1_CIDR_PREFIX="${CP1_IP%.*}"
CP1_INIT_TIMEOUT_SECONDS="${CP1_INIT_TIMEOUT_SECONDS:-1800}"
CP1_PROGRESS_FILE="/vagrant/.cluster/cp1-progress"
CP1_PREPULL_IMAGES="${CP1_PREPULL_IMAGES:-true}"
CP1_PREPULL_TIMEOUT_SECONDS="${CP1_PREPULL_TIMEOUT_SECONDS:-1200}"
CP1_PROGRESS_INTERVAL_SECONDS="${CP1_PROGRESS_INTERVAL_SECONDS:-20}"

count_k8s_images() {
  if command -v crictl >/dev/null 2>&1; then
    crictl images 2>/dev/null | awk 'NR>1 && $1 ~ /(registry\.k8s\.io|k8s\.gcr\.io|coredns|etcd)/ {c++} END{print c+0}'
    return 0
  fi
  if command -v ctr >/dev/null 2>&1; then
    ctr -n k8s.io images ls 2>/dev/null | awk 'NR>1 && $1 ~ /(registry\.k8s\.io|k8s\.gcr\.io|coredns|etcd)/ {c++} END{print c+0}'
    return 0
  fi
  echo "unknown"
}

start_progress_heartbeat() {
  local phase="$1"
  local start_ts="$2"
  (
    while true; do
      sleep "${CP1_PROGRESS_INTERVAL_SECONDS}" || exit 0
      local now elapsed last_line img_count
      now="$(date +%s)"
      elapsed="$((now - start_ts))"
      last_line="$(tail -n 1 "${KUBEADM_LOG}" 2>/dev/null || true)"
      img_count="$(count_k8s_images)"
      echo "${phase}: elapsed=${elapsed}s cached_images=${img_count} last='${last_line}'" >>"${CP1_PROGRESS_FILE}"
    done
  ) &
  echo "$!"
}

stop_progress_heartbeat() {
  local hb_pid="${1:-}"
  if [[ -n "${hb_pid}" ]]; then
    kill "${hb_pid}" >/dev/null 2>&1 || true
    wait "${hb_pid}" 2>/dev/null || true
  fi
}

enforce_cp1_private_ip() {
  local iface target_cidr addr
  target_cidr="${CP1_IP}/24"
  iface="eth1"

  if ! ip link show "${iface}" >/dev/null 2>&1; then
    iface="$(ip -o link show | awk -F': ' '$2 != "lo" && $2 != "eth0" {print $2; exit}' || true)"
  fi
  if [[ -z "${iface}" ]]; then
    return 0
  fi

  while IFS= read -r addr; do
    if [[ "${addr}" == "${target_cidr}" ]]; then
      continue
    fi
    if [[ "${addr}" =~ ^${CP1_CIDR_PREFIX//./\\.}\.[0-9]+/24$ ]]; then
      ip -4 addr del "${addr}" dev "${iface}" || true
    fi
  done < <(ip -o -4 addr show dev "${iface}" | awk '{print $4}')

  if ! ip -o -4 addr show dev "${iface}" | awk '{print $4}' | grep -qx "${target_cidr}"; then
    ip -4 addr add "${target_cidr}" dev "${iface}" || true
  fi
}

mkdir -p /vagrant/.cluster
rm -f /vagrant/.cluster/failed
rm -f "${KUBEADM_LOG}"

on_error() {
  local exit_code="$1"
  local line_no="${2:-unknown}"
  local failed_cmd="${3:-unknown}"
  {
    echo "cp1 bootstrap failed with exit code ${exit_code}"
    echo "line: ${line_no}"
    echo "command: ${failed_cmd}"
    if [[ -s "${KUBEADM_LOG}" ]]; then
      echo "kubeadm log tail:"
      tail -n 60 "${KUBEADM_LOG}"
    fi
  } >/vagrant/.cluster/failed
  cp "${KUBEADM_LOG}" /vagrant/.cluster/cp1-kubeadm-error.log 2>/dev/null || true
  journalctl -u kubelet --no-pager -n 300 >/vagrant/.cluster/cp1-kubelet-error.log || true
  journalctl -u containerd --no-pager -n 200 >/vagrant/.cluster/cp1-containerd-error.log || true
}

trap 'on_error $? ${LINENO} "${BASH_COMMAND}"' ERR

run_kubeadm_init() {
  local rc hb_pid start_ts
  start_ts="$(date +%s)"
  echo "starting kubeadm init (timeout=${CP1_INIT_TIMEOUT_SECONDS}s) at $(date -Iseconds)" >"${CP1_PROGRESS_FILE}"
  hb_pid="$(start_progress_heartbeat "kubeadm-init" "${start_ts}")"
  timeout --foreground --signal=TERM --kill-after=60 "${CP1_INIT_TIMEOUT_SECONDS}" \
  kubeadm init \
    --apiserver-advertise-address "${CP1_IP}" \
    --apiserver-cert-extra-sans "${CP1_IP}" \
    --apiserver-cert-extra-sans "${CONTROL_PLANE_ENDPOINT%:*}" \
    --apiserver-cert-extra-sans "${CONTROL_PLANE_ENDPOINT_HOST}" \
    --control-plane-endpoint "${CONTROL_PLANE_ENDPOINT}" \
    --pod-network-cidr "${KUBE_POD_CIDR}" \
    --service-cidr "${KUBE_SERVICE_CIDR}" \
    --kubernetes-version "v${KUBE_VERSION%%-*}" \
    --upload-certs 2>&1 | tee -a "${KUBEADM_LOG}"
  rc=${PIPESTATUS[0]}
  stop_progress_heartbeat "${hb_pid}"
  if [[ "${rc}" -eq 124 ]]; then
    {
      echo "kubeadm init timed out after ${CP1_INIT_TIMEOUT_SECONDS}s"
      echo "See ${KUBEADM_LOG} for partial output."
    } >>"${CP1_PROGRESS_FILE}"
  fi
  return "${rc}"
}

bootstrap_control_plane() {
  if [[ "${CP1_PREPULL_IMAGES}" == "true" ]]; then
    local prepull_rc prepull_hb_pid prepull_start_ts
    prepull_start_ts="$(date +%s)"
    echo "pre-pulling control-plane images (timeout=${CP1_PREPULL_TIMEOUT_SECONDS}s) at $(date -Iseconds)" >"${CP1_PROGRESS_FILE}"
    prepull_hb_pid="$(start_progress_heartbeat "prepull-images" "${prepull_start_ts}")"
    timeout --foreground --signal=TERM --kill-after=30 "${CP1_PREPULL_TIMEOUT_SECONDS}" \
      kubeadm config images pull --kubernetes-version "v${KUBE_VERSION%%-*}" 2>&1 | tee -a "${KUBEADM_LOG}"
    prepull_rc=${PIPESTATUS[0]}
    stop_progress_heartbeat "${prepull_hb_pid}"
    if [[ "${prepull_rc}" -ne 0 ]]; then
      echo "image pre-pull failed or timed out (rc=${prepull_rc}); continuing with kubeadm init" >>"${CP1_PROGRESS_FILE}"
    else
      echo "image pre-pull complete at $(date -Iseconds)" >>"${CP1_PROGRESS_FILE}"
    fi
  fi
  run_kubeadm_init
}

enforce_cp1_private_ip
if ! wait_for_ip "${CP1_IP}" "${CP1_WAIT_IP_TIMEOUT_SECONDS}"; then
  {
    echo "cp1 bootstrap network precheck failed"
    echo "expected control-plane IP: ${CP1_IP}"
    echo "timeout_seconds: ${CP1_WAIT_IP_TIMEOUT_SECONDS}"
    echo "observed_ipv4:"
    ip -o -4 addr show || true
  } >/vagrant/.cluster/failed
  ip -o -4 addr show >/vagrant/.cluster/cp1-ipv4.log 2>/dev/null || true
  ip route show >/vagrant/.cluster/cp1-routes.log 2>/dev/null || true
  exit 1
fi

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "Control plane already initialized, refreshing join artifacts"
  echo "control-plane already initialized at $(date -Iseconds)" >"${CP1_PROGRESS_FILE}"
else
  if ! bootstrap_control_plane; then
    echo "First kubeadm init attempt failed, collecting logs and retrying once"
    echo "first kubeadm init attempt failed, retrying at $(date -Iseconds)" >"${CP1_PROGRESS_FILE}"
    journalctl -u kubelet --no-pager -n 200 >/vagrant/.cluster/cp1-kubelet-init.log || true
    kubeadm reset -f || true
    systemctl restart containerd kubelet || true
    sleep 10
    bootstrap_control_plane
  fi
fi

mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config

mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube
chmod 600 /home/vagrant/.kube/config

cp /etc/kubernetes/admin.conf /vagrant/.cluster/admin.conf
chmod 600 /vagrant/.cluster/admin.conf

wait_for_apiserver /etc/kubernetes/admin.conf 420

JOIN_CMD="$(kubeadm token create --print-join-command)"
CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1)"
printf '%s\n' "${JOIN_CMD}" >/vagrant/.cluster/join.sh
printf '%s\n' "${CERT_KEY}" >/vagrant/.cluster/certificate-key
chmod 600 /vagrant/.cluster/join.sh /vagrant/.cluster/certificate-key

export KUBECONFIG=/etc/kubernetes/admin.conf

case "${KUBE_CNI}" in
  flannel)
    kubectl apply -f "${KUBE_CNI_MANIFEST_FLANNEL}"
    ;;
  calico)
    kubectl apply -f "${KUBE_CNI_MANIFEST_CALICO}"
    ;;
  cilium)
    kubectl apply -f "${KUBE_CNI_MANIFEST_CILIUM}"
    ;;
  *)
    echo "Unsupported KUBE_CNI=${KUBE_CNI}. Supported: flannel, calico, cilium" >&2
    exit 1
    ;;
esac

test -s /vagrant/.cluster/join.sh
test -s /vagrant/.cluster/certificate-key
test -s /vagrant/.cluster/admin.conf
touch /vagrant/.cluster/ready
echo "cp1 bootstrap complete at $(date -Iseconds)" >"${CP1_PROGRESS_FILE}"
trap - ERR
