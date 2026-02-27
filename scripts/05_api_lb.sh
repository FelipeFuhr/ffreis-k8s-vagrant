#!/usr/bin/env bash
set -euo pipefail

NODE_NAME="${NODE_NAME:-api-lb}"
CP_COUNT="${CP_COUNT:-1}"
NETWORK_PREFIX="${NETWORK_PREFIX:-10.30.0}"
API_LB_HOSTNAME="${API_LB_HOSTNAME:-k8s-api.local}"
API_LB_IP="${API_LB_IP:-10.30.0.5}"

if [[ -f /vagrant/scripts/lib_apt.sh ]]; then
  # shellcheck source=/vagrant/scripts/lib_apt.sh
  source /vagrant/scripts/lib_apt.sh
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=lib_apt.sh
  source "${SCRIPT_DIR}/lib_apt.sh"
fi

export DEBIAN_FRONTEND=noninteractive
install_missing_no_upgrade haproxy

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
