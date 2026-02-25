#!/usr/bin/env bash

node_actual_hostname() {
  local machine="$1"
  local vagrant_retry="$2"
  "${vagrant_retry}" vagrant ssh "${machine}" -c 'hostname -s' 2>/dev/null | tr -d '\r' | tail -n1 | tr -d '[:space:]'
}

node_has_expected_ip() {
  local machine="$1"
  local expected_ip="$2"
  local vagrant_retry="$3"
  "${vagrant_retry}" vagrant ssh "${machine}" -c "ip -o -4 addr show | awk '{print \$4}' | grep -qx '${expected_ip}/24'" >/dev/null 2>&1
}

node_actual_cpu_count() {
  local machine="$1"
  local vagrant_retry="$2"
  "${vagrant_retry}" vagrant ssh "${machine}" -c 'nproc' 2>/dev/null | tr -d '\r' | tail -n1 | tr -d '[:space:]'
}

node_actual_memory_mib() {
  local machine="$1"
  local vagrant_retry="$2"
  "${vagrant_retry}" vagrant ssh "${machine}" -c "awk '/MemTotal/ {print int(\$2/1024)}' /proc/meminfo" 2>/dev/null | tr -d '\r' | tail -n1 | tr -d '[:space:]'
}

node_haproxy_active() {
  local machine="$1"
  local vagrant_retry="$2"
  "${vagrant_retry}" vagrant ssh "${machine}" -c "systemctl is-active haproxy >/dev/null 2>&1" >/dev/null 2>&1
}
