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
source_script_libs logging retry

KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CHANNEL="${KUBE_CHANNEL:-v1.30}"
KUBE_CONTAINERD_VERSION="${KUBE_CONTAINERD_VERSION:-}"
KUBE_PAUSE_IMAGE="${KUBE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_NAME="${NODE_NAME:-unknown}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

log "Configuring kernel modules and sysctls"
cat >/etc/modules-load.d/k8s.conf <<CFG
overlay
br_netfilter
CFG
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<CFG
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
CFG
sysctl --system >/dev/null

log "Disabling swap"
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

log "Installing Kubernetes dependencies"
export DEBIAN_FRONTEND=noninteractive
configure_apt_proxy "${KUBE_APT_PROXY}"
retry 5 strict_apt_update
retry 5 apt-get install -y apt-transport-https ca-certificates curl gpg jq

install -m 0755 -d /etc/apt/keyrings
tmp_key="$(mktemp)"
retry_download "https://pkgs.k8s.io/core:/stable:/${KUBE_CHANNEL}/deb/Release.key" "${tmp_key}" 8
gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${tmp_key}"
if ! gpg --show-keys --with-colons /etc/apt/keyrings/kubernetes-apt-keyring.gpg | grep -q '234654DA9A296436'; then
  echo "Kubernetes apt key fingerprint mismatch or missing expected key ID" >&2
  exit 1
fi
rm -f "${tmp_key}"
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<CFG
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_CHANNEL}/deb/ /
CFG
chmod 0644 /etc/apt/sources.list.d/kubernetes.list

retry 5 strict_apt_update
containerd_pkg="containerd"
if [[ -n "${KUBE_CONTAINERD_VERSION}" ]]; then
  containerd_pkg="containerd=${KUBE_CONTAINERD_VERSION}"
fi
retry 5 apt-get install -y "${containerd_pkg}" kubelet="${KUBE_VERSION}" kubeadm="${KUBE_VERSION}" kubectl="${KUBE_VERSION}"
apt-mark hold kubelet kubeadm kubectl

log "Configuring containerd"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
escaped_pause_image="$(printf '%s' "${KUBE_PAUSE_IMAGE}" | sed -e 's/[&\\#]/\\&/g')"
sed -Ei "s#^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*\$#\\1\"${escaped_pause_image}\"#" /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable containerd kubelet
systemctl restart containerd kubelet

if [[ -n "${SSH_PUBKEY}" ]]; then
  log "Injecting provided SSH public key"
  install -d -m 0700 -o vagrant -g vagrant /home/vagrant/.ssh
  printf '%s\n' "${SSH_PUBKEY}" >>/home/vagrant/.ssh/authorized_keys
  chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
  chmod 0600 /home/vagrant/.ssh/authorized_keys
fi

log "Common node setup complete"
