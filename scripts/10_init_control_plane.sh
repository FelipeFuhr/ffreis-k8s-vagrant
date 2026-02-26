#!/usr/bin/env bash
set -euo pipefail

CP1_IP="${CP1_IP:-10.30.0.11}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${CP1_IP}:6443}"
CONTROL_PLANE_ENDPOINT_HOST="${CONTROL_PLANE_ENDPOINT_HOST:-cp1}"
KUBE_POD_CIDR="${KUBE_POD_CIDR:-10.244.0.0/16}"
KUBE_SERVICE_CIDR="${KUBE_SERVICE_CIDR:-10.96.0.0/12}"
KUBE_CNI="${KUBE_CNI:-flannel}"
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
WAIT_REPORT_INTERVAL_SECONDS="${WAIT_REPORT_INTERVAL_SECONDS:-60}"
EXTERNAL_ETCD_ENDPOINTS="${EXTERNAL_ETCD_ENDPOINTS:-}"

mkdir -p /vagrant/.cluster
rm -f /vagrant/.cluster/failed

on_error() {
  local exit_code="$1"
  echo "cp1 bootstrap failed with exit code ${exit_code}" >/vagrant/.cluster/failed
  journalctl -u kubelet --no-pager -n 300 >/vagrant/.cluster/cp1-kubelet-error.log || true
}

trap 'on_error $?' ERR

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

wait_for_ip() {
  local waited timeout report_interval
  waited=0
  timeout=180
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  if [[ "${report_interval}" -lt 3 ]]; then
    report_interval=3
  fi

  until ip -o -4 addr show | awk '{print $4}' | grep -q "^${CP1_IP}/"; do
    if (( waited == 0 || waited % report_interval == 0 )); then
      log_wait_progress "Waiting for node IP ${CP1_IP}" "${waited}" "${timeout}" "${report_interval}"
    fi

    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for ${CP1_IP} on this node" >&2
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

wait_for_apiserver() {
  local waited timeout report_interval
  waited=0
  timeout=420
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  if [[ "${report_interval}" -lt 5 ]]; then
    report_interval=5
  fi

  until kubectl --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz >/dev/null 2>&1; do
    if (( waited == 0 || waited % report_interval == 0 )); then
      log_wait_progress "Waiting for Kubernetes API readiness" "${waited}" "${timeout}" "${report_interval}"
    fi

    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "Timed out waiting for Kubernetes API readiness" >&2
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

wait_for_external_etcd() {
  local timeout interval report_interval waited endpoint healthy_count total_count
  timeout=420
  interval=5
  report_interval="${WAIT_REPORT_INTERVAL_SECONDS}"
  waited=0

  if [[ "${report_interval}" -lt "${interval}" ]]; then
    report_interval="${interval}"
  fi

  while true; do
    healthy_count=0
    total_count=0
    IFS=',' read -r -a endpoints <<<"${EXTERNAL_ETCD_ENDPOINTS}"
    for endpoint in "${endpoints[@]}"; do
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

bootstrap_control_plane() {
  local endpoint_host
  endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
  if [[ -z "${EXTERNAL_ETCD_ENDPOINTS}" ]]; then
    echo "EXTERNAL_ETCD_ENDPOINTS is required" >&2
    return 1
  fi

  wait_for_external_etcd

  cat >/tmp/kubeadm-init.yaml <<CFG
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CP1_IP}
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${KUBE_VERSION%%-*}
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}
networking:
  podSubnet: ${KUBE_POD_CIDR}
  serviceSubnet: ${KUBE_SERVICE_CIDR}
apiServer:
  certSANs:
  - ${CP1_IP}
  - ${endpoint_host}
  - ${CONTROL_PLANE_ENDPOINT_HOST}
etcd:
  external:
    endpoints:
CFG

  IFS=',' read -r -a endpoints <<<"${EXTERNAL_ETCD_ENDPOINTS}"
  for endpoint in "${endpoints[@]}"; do
    printf '    - %s\n' "${endpoint}" >>/tmp/kubeadm-init.yaml
  done

  # Upload certs in a dedicated step later after ensuring a fresh bootstrap token exists.
  kubeadm init --config /tmp/kubeadm-init.yaml
}

wait_for_ip

if [[ -f /etc/kubernetes/admin.conf ]]; then
  echo "Control plane already initialized, refreshing join artifacts"
else
  if ! bootstrap_control_plane; then
    echo "First kubeadm init attempt failed, collecting logs and retrying once"
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

wait_for_apiserver

build_shared_pki_bundle() {
  local bundle_root
  local src
  local rel
  local required
  local optional

  bundle_root="$(mktemp -d)"
  mkdir -p "${bundle_root}/pki"

  required=(
    "ca.crt"
    "ca.key"
    "sa.pub"
    "sa.key"
    "front-proxy-ca.crt"
    "front-proxy-ca.key"
  )

  optional=(
    "apiserver-etcd-client.crt"
    "apiserver-etcd-client.key"
    "external-etcd-ca.crt"
    "external-etcd.crt"
    "external-etcd.key"
    "etcd/ca.crt"
    "etcd/ca.key"
  )

  for rel in "${required[@]}"; do
    src="/etc/kubernetes/pki/${rel}"
    if [[ ! -f "${src}" ]]; then
      echo "Missing required PKI file for control-plane join: ${src}" >&2
      rm -rf "${bundle_root}"
      return 1
    fi
    mkdir -p "${bundle_root}/pki/$(dirname "${rel}")"
    cp "${src}" "${bundle_root}/pki/${rel}"
  done

  for rel in "${optional[@]}"; do
    src="/etc/kubernetes/pki/${rel}"
    if [[ -f "${src}" ]]; then
      mkdir -p "${bundle_root}/pki/$(dirname "${rel}")"
      cp "${src}" "${bundle_root}/pki/${rel}"
    fi
  done

  tar -C "${bundle_root}" -czf /vagrant/.cluster/pki-control-plane.tgz pki
  rm -rf "${bundle_root}"
}

JOIN_CMD="$(kubeadm token create --print-join-command)"
CERT_KEY="$(kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -n 1)"
printf '%s\n' "${JOIN_CMD}" >/vagrant/.cluster/join.sh
printf '%s\n' "${CERT_KEY}" >/vagrant/.cluster/certificate-key
chmod 600 /vagrant/.cluster/join.sh /vagrant/.cluster/certificate-key
# Share only cluster-wide PKI (not node-specific apiserver certs) for cp2+ join.
build_shared_pki_bundle
chmod 600 /vagrant/.cluster/pki-control-plane.tgz

export KUBECONFIG=/etc/kubernetes/admin.conf

case "${KUBE_CNI}" in
  flannel)
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    ;;
  calico)
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml
    ;;
  cilium)
    kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.16.5/install/kubernetes/quick-install.yaml
    ;;
  *)
    echo "Unsupported KUBE_CNI=${KUBE_CNI}. Supported: flannel, calico, cilium" >&2
    exit 1
    ;;
esac

touch /vagrant/.cluster/ready
trap - ERR
