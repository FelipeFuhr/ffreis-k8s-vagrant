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

mkdir -p /vagrant/.cluster
rm -f /vagrant/.cluster/failed

on_error() {
  local exit_code="$1"
  echo "cp1 bootstrap failed with exit code ${exit_code}" >/vagrant/.cluster/failed
  journalctl -u kubelet --no-pager -n 300 >/vagrant/.cluster/cp1-kubelet-error.log || true
}

trap 'on_error $?' ERR

bootstrap_control_plane() {
  local endpoint_host
  endpoint_host="${CONTROL_PLANE_ENDPOINT%:*}"
  kubeadm init \
    --apiserver-advertise-address "${CP1_IP}" \
    --apiserver-cert-extra-sans "${CP1_IP}" \
    --apiserver-cert-extra-sans "${endpoint_host}" \
    --apiserver-cert-extra-sans "${CONTROL_PLANE_ENDPOINT_HOST}" \
    --control-plane-endpoint "${CONTROL_PLANE_ENDPOINT}" \
    --pod-network-cidr "${KUBE_POD_CIDR}" \
    --service-cidr "${KUBE_SERVICE_CIDR}" \
    --kubernetes-version "v${KUBE_VERSION%%-*}" \
    --upload-certs
}

wait_for_ip "${CP1_IP}" 180

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

touch /vagrant/.cluster/ready
trap - ERR
