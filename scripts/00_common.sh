#!/usr/bin/env bash
set -euo pipefail

KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_NAME="${NODE_NAME:-unknown}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

log() {
  printf '[%s] %s\n' "${NODE_NAME}" "$*"
}

retry() {
  local attempts="$1"
  shift
  local n=1
  until "$@"; do
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    n=$((n + 1))
    sleep 2
  done
}

retry_download() {
  local url="$1"
  local out_file="$2"
  local attempts="${3:-8}"
  local n=1
  until curl -fsSL --connect-timeout 10 --max-time 60 "${url}" -o "${out_file}"; do
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    n=$((n + 1))
    sleep 3
  done
}

strict_apt_update() {
  apt-get update -y -o APT::Update::Error-Mode=any
}

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
retry 5 strict_apt_update
retry 5 apt-get install -y apt-transport-https ca-certificates curl gpg jq

install -m 0755 -d /etc/apt/keyrings
tmp_key="$(mktemp)"
retry_download "https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key" "${tmp_key}" 8
gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${tmp_key}"
if ! gpg --show-keys --with-colons /etc/apt/keyrings/kubernetes-apt-keyring.gpg | grep -q '234654DA9A296436'; then
  echo "Kubernetes apt key fingerprint mismatch or missing expected key ID" >&2
  exit 1
fi
rm -f "${tmp_key}"
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat >/etc/apt/sources.list.d/kubernetes.list <<CFG
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /
CFG
chmod 0644 /etc/apt/sources.list.d/kubernetes.list

retry 5 strict_apt_update
retry 5 apt-get install -y containerd kubelet="${KUBE_VERSION}" kubeadm="${KUBE_VERSION}" kubectl="${KUBE_VERSION}"
apt-mark hold kubelet kubeadm kubectl

log "Configuring containerd"
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -Ei 's#^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$#\1"registry.k8s.io/pause:3.9"#' /etc/containerd/config.toml
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
