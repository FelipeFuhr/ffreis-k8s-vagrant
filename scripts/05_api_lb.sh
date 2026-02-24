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
source_script_libs retry

NODE_NAME="${NODE_NAME:-api-lb}"
CP_COUNT="${CP_COUNT:-1}"
NETWORK_PREFIX="${NETWORK_PREFIX:-10.30.0}"
API_LB_HOSTNAME="${API_LB_HOSTNAME:-k8s-api.local}"
API_LB_IP="${API_LB_IP:-10.30.0.5}"
KUBE_HAPROXY_VERSION="${KUBE_HAPROXY_VERSION:-}"
KUBE_APT_PROXY="${KUBE_APT_PROXY:-}"

export DEBIAN_FRONTEND=noninteractive
configure_apt_proxy "${KUBE_APT_PROXY}"
retry 5 strict_apt_update
haproxy_pkg="haproxy"
if [[ -n "${KUBE_HAPROXY_VERSION}" ]]; then
  haproxy_pkg="haproxy=${KUBE_HAPROXY_VERSION}"
fi
retry 5 apt-get install -y "${haproxy_pkg}"

if ! grep -q "${API_LB_HOSTNAME}" /etc/hosts; then
  printf '%s %s\n' "${API_LB_IP}" "${API_LB_HOSTNAME}" >>/etc/hosts
fi

cat >/etc/haproxy/haproxy.cfg <<CFG
global
  log /dev/log local0
  log /dev/log local1 notice
  daemon

defaults
  log global
  mode tcp
  timeout connect 10s
  timeout client 1m
  timeout server 1m

frontend k8s_api_frontend
  bind *:6443
  default_backend k8s_api_backend

backend k8s_api_backend
  balance roundrobin
  option tcp-check
CFG

for idx in $(seq 1 "${CP_COUNT}"); do
  ip_octet=$((10 + idx))
  printf '  server cp%s %s.%s:6443 check fall 3 rise 2\n' "${idx}" "${NETWORK_PREFIX}" "${ip_octet}" >>/etc/haproxy/haproxy.cfg
done

systemctl enable haproxy
systemctl restart haproxy

echo "[${NODE_NAME}] API load balancer configured at ${API_LB_IP}:6443"
