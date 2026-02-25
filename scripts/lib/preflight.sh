#!/usr/bin/env bash

host_mem_gib() {
  awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

host_cpu_count() {
  nproc 2>/dev/null || echo 0
}

required_mem_gib() {
  local cp_count="${KUBE_CP_COUNT:-1}"
  local worker_count="${KUBE_WORKER_COUNT:-0}"
  local cp_mem_mib="${KUBE_CP_MEMORY:-4096}"
  local worker_mem_mib="${KUBE_WORKER_MEMORY:-3072}"
  local api_lb_enabled="${KUBE_API_LB_ENABLED:-true}"
  local api_lb_mem_mib="${KUBE_API_LB_MEMORY:-1024}"

  local total_mib=$((cp_count * cp_mem_mib + worker_count * worker_mem_mib))
  if [[ "${api_lb_enabled}" == "true" ]]; then
    total_mib=$((total_mib + api_lb_mem_mib))
  fi
  # Add host overhead budget for libvirt/qemu
  total_mib=$((total_mib + 2048))
  echo $(( (total_mib + 1023) / 1024 ))
}

required_cpu_count() {
  local cp_count="${KUBE_CP_COUNT:-1}"
  local worker_count="${KUBE_WORKER_COUNT:-0}"
  local cp_cpus="${KUBE_CP_CPUS:-2}"
  local worker_cpus="${KUBE_WORKER_CPUS:-2}"
  local api_lb_enabled="${KUBE_API_LB_ENABLED:-true}"
  local api_lb_cpus="${KUBE_API_LB_CPUS:-1}"

  local total=$((cp_count * cp_cpus + worker_count * worker_cpus))
  if [[ "${api_lb_enabled}" == "true" ]]; then
    total=$((total + api_lb_cpus))
  fi
  # Leave at least 1 host CPU free.
  echo $((total + 1))
}

cidr_conflicts_host_routes() {
  local network_prefix="${KUBE_NETWORK_PREFIX:-10.30.0}"
  local pod_cidr="${KUBE_POD_CIDR:-10.244.0.0/16}"
  local service_cidr="${KUBE_SERVICE_CIDR:-10.96.0.0/12}"
  local routes
  routes="$(ip -4 route show 2>/dev/null || true)"

  if grep -Eq "^${network_prefix//./\\.}\.0/24\b" <<<"${routes}"; then
    echo "host route conflict: node network ${network_prefix}.0/24 already present"
    return 0
  fi
  if grep -Eq "^${pod_cidr//./\\.}\b" <<<"${routes}"; then
    echo "host route conflict: pod cidr ${pod_cidr} already present"
    return 0
  fi
  if grep -Eq "^${service_cidr//./\\.}\b" <<<"${routes}"; then
    echo "host route conflict: service cidr ${service_cidr} already present"
    return 0
  fi
  return 1
}

suggest_free_network_prefix() {
  local i
  local routes
  routes="$(ip -4 route show 2>/dev/null || true)"
  for i in $(seq 30 99); do
    if ! grep -Eq "^10\.${i}\.0\.0/16\b|^10\.${i}\.0\.0/24\b" <<<"${routes}"; then
      echo "10.${i}.0"
      return 0
    fi
  done
  echo "172.29.250"
}
