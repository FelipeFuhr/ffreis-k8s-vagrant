#!/usr/bin/env bash
set -euo pipefail

KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_NAME="${NODE_NAME:-unknown}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

log() {
  printf '[%s] %s\n' "${NODE_NAME}" "$*"
}

if [[ -f /vagrant/scripts/lib_apt.sh ]]; then
  # shellcheck source=/vagrant/scripts/lib_apt.sh
  source /vagrant/scripts/lib_apt.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib_apt.sh
  source "${SCRIPT_DIR}/lib_apt.sh"
fi

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
install_missing_no_upgrade apt-transport-https ca-certificates curl gpg jq

kube_minor="$(awk -F. '{print $1 "." $2}' <<<"${KUBE_VERSION%%-*}")"
if [[ ! "${kube_minor}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid KUBE_VERSION format: ${KUBE_VERSION}" >&2
  exit 1
fi
k8s_repo_url="https://pkgs.k8s.io/core:/stable:/v${kube_minor}/deb/"

install -m 0755 -d /etc/apt/keyrings
if ! [[ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]] \
  || ! gpg --show-keys --with-colons /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null | grep -q '234654DA9A296436'; then
  tmp_key="$(mktemp)"
  retry_download "${k8s_repo_url}Release.key" "${tmp_key}" 8
  gpg --dearmor --batch --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${tmp_key}"
  rm -f "${tmp_key}"
fi
if ! gpg --show-keys --with-colons /etc/apt/keyrings/kubernetes-apt-keyring.gpg | grep -q '234654DA9A296436'; then
  echo "Kubernetes apt key fingerprint mismatch or missing expected key ID" >&2
  exit 1
fi
chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

needs_k8s_repo_update=0
if [[ ! -f /etc/apt/sources.list.d/kubernetes.list ]] \
  || ! grep -q "${k8s_repo_url}" /etc/apt/sources.list.d/kubernetes.list; then
  cat >/etc/apt/sources.list.d/kubernetes.list <<CFG
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${k8s_repo_url} /
CFG
  needs_k8s_repo_update=1
fi
chmod 0644 /etc/apt/sources.list.d/kubernetes.list

# Ensure apt has indexed the Kubernetes repo before installing kube* packages.
if ! compgen -G '/var/lib/apt/lists/*pkgs.k8s.io*' >/dev/null; then
  needs_k8s_repo_update=1
fi

kubelet_installed_version="$(pkg_version kubelet)"
kubeadm_installed_version="$(pkg_version kubeadm)"
kubectl_installed_version="$(pkg_version kubectl)"
containerd_installed=0
if pkg_installed containerd; then
  containerd_installed=1
fi

if [[ "${containerd_installed}" -eq 0 \
  || "${kubelet_installed_version}" != "${KUBE_VERSION}" \
  || "${kubeadm_installed_version}" != "${KUBE_VERSION}" \
  || "${kubectl_installed_version}" != "${KUBE_VERSION}" ]]; then
  if [[ "${needs_k8s_repo_update}" -eq 1 ]]; then
    retry_cmd 5 apt-get update -y -o APT::Update::Error-Mode=any
  else
    apt_update_if_stale
  fi
  retry_cmd 5 apt-get install -y containerd kubelet="${KUBE_VERSION}" kubeadm="${KUBE_VERSION}" kubectl="${KUBE_VERSION}"
fi
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
