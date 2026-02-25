#!/usr/bin/env bash

run_base_common_provision() {
KUBE_VERSION="${KUBE_VERSION:-1.30.6-1.1}"
KUBE_CHANNEL="${KUBE_CHANNEL:-v1.30}"
KUBE_CONTAINERD_VERSION="${KUBE_CONTAINERD_VERSION:-}"
KUBE_PAUSE_IMAGE="${KUBE_PAUSE_IMAGE:-registry.k8s.io/pause:3.9}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"
CP_COUNT="${CP_COUNT:-1}"
WORKER_COUNT="${WORKER_COUNT:-2}"
NETWORK_PREFIX="${NETWORK_PREFIX:-10.30.0}"
KUBE_API_LB_ENABLED="${KUBE_API_LB_ENABLED:-true}"
API_LB_IP="${API_LB_IP:-${NETWORK_PREFIX}.5}"
API_LB_HOSTNAME="${API_LB_HOSTNAME:-k8s-api.local}"
NODE_ROLE="${NODE_ROLE:-worker}"
NODE_NAME="${NODE_NAME:-unknown}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

expected_node_private_ip() {
  local idx
  case "${NODE_NAME}" in
    cp*)
      idx="${NODE_NAME#cp}"
      if [[ "${idx}" =~ ^[0-9]+$ ]]; then
        echo "${NETWORK_PREFIX}.$((10 + idx))"
        return 0
      fi
      ;;
    worker*)
      idx="${NODE_NAME#worker}"
      if [[ "${idx}" =~ ^[0-9]+$ ]]; then
        echo "${NETWORK_PREFIX}.$((100 + idx))"
        return 0
      fi
      ;;
  esac
  return 1
}

enforce_expected_hostname() {
  local current
  current="$(hostname -s 2>/dev/null || true)"
  if [[ "${current}" == "${NODE_NAME}" ]]; then
    return 0
  fi
  hostnamectl set-hostname "${NODE_NAME}" || true
  printf '%s\n' "${NODE_NAME}" >/etc/hostname || true
}

enforce_expected_private_ip() {
  local expected_ip iface found_expected cidr addr
  expected_ip="$(expected_node_private_ip || true)"
  if [[ -z "${expected_ip}" ]]; then
    return 0
  fi

  iface="eth1"
  if ! ip link show "${iface}" >/dev/null 2>&1; then
    iface="$(ip -o link show | awk -F': ' '$2 != "lo" && $2 != "eth0" {print $2; exit}' || true)"
  fi
  if [[ -z "${iface}" ]]; then
    log "No private interface found to enforce expected IP ${expected_ip}"
    return 0
  fi

  cidr="${expected_ip}/24"
  found_expected=0
  while IFS= read -r addr; do
    if [[ "${addr}" == "${cidr}" ]]; then
      found_expected=1
      continue
    fi
    if [[ "${addr}" =~ ^${NETWORK_PREFIX//./\\.}\.[0-9]+/24$ ]]; then
      ip -4 addr del "${addr}" dev "${iface}" || true
    fi
  done < <(ip -o -4 addr show dev "${iface}" | awk '{print $4}')

  if [[ "${found_expected}" -eq 0 ]]; then
    ip -4 addr add "${cidr}" dev "${iface}" || true
  fi

  log "Private IP on ${iface} enforced to ${cidr}"
}

configure_cluster_hosts() {
  local tmp_hosts
  tmp_hosts="$(mktemp)"

  awk '
    BEGIN { skip=0 }
    /^# BEGIN K8S-LAB HOSTS$/ { skip=1; next }
    /^# END K8S-LAB HOSTS$/ { skip=0; next }
    skip==0 { print }
  ' /etc/hosts >"${tmp_hosts}"

  {
    echo "# BEGIN K8S-LAB HOSTS"
    if [[ "${KUBE_API_LB_ENABLED}" == "true" ]]; then
      printf '%s api-lb %s\n' "${API_LB_IP}" "${API_LB_HOSTNAME}"
    fi
    for i in $(seq 1 "${CP_COUNT}"); do
      printf '%s.%s cp%s\n' "${NETWORK_PREFIX}" "$((10 + i))" "${i}"
    done
    for i in $(seq 1 "${WORKER_COUNT}"); do
      printf '%s.%s worker%s\n' "${NETWORK_PREFIX}" "$((100 + i))" "${i}"
    done
    echo "# END K8S-LAB HOSTS"
  } >>"${tmp_hosts}"

  cat "${tmp_hosts}" >/etc/hosts
  rm -f "${tmp_hosts}"
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
log "Configuring static host mappings for cluster nodes"
enforce_expected_hostname
enforce_expected_private_ip
configure_cluster_hosts
configure_apt_proxy "${KUBE_APT_PROXY}"
log "Disabling background apt jobs and waiting for apt locks"
disable_apt_background_jobs
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
}
