#!/usr/bin/env bash

compute_backoff_sleep_seconds() {
  local attempt_idx="$1"
  local base_sleep_seconds="$2"
  local backoff_factor="$3"
  local max_sleep_seconds="$4"
  local sleep_value="${base_sleep_seconds}"
  local i

  for ((i = 1; i < attempt_idx; i++)); do
    sleep_value=$((sleep_value * backoff_factor))
    if ((sleep_value >= max_sleep_seconds)); then
      sleep_value="${max_sleep_seconds}"
      break
    fi
  done

  echo "${sleep_value}"
}

retry() {
  local attempts="$1"
  shift
  local n=1
  local base_sleep_seconds="${KUBE_RETRY_SLEEP_SECONDS:-${RETRY_SLEEP_SECONDS:-2}}"
  local backoff_factor="${KUBE_RETRY_BACKOFF_FACTOR:-${RETRY_BACKOFF_FACTOR:-2}}"
  local max_sleep_seconds="${KUBE_RETRY_MAX_SLEEP_SECONDS:-${RETRY_MAX_SLEEP_SECONDS:-30}}"
  local sleep_seconds

  until "$@"; do
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    sleep_seconds="$(compute_backoff_sleep_seconds "${n}" "${base_sleep_seconds}" "${backoff_factor}" "${max_sleep_seconds}")"
    n=$((n + 1))
    sleep "${sleep_seconds}"
  done
}

retry_download() {
  local url="$1"
  local out_file="$2"
  local attempts="${3:-8}"
  local n=1
  local base_sleep_seconds="${KUBE_DOWNLOAD_RETRY_SLEEP_SECONDS:-${DOWNLOAD_RETRY_SLEEP_SECONDS:-3}}"
  local backoff_factor="${KUBE_DOWNLOAD_RETRY_BACKOFF_FACTOR:-${DOWNLOAD_RETRY_BACKOFF_FACTOR:-2}}"
  local max_sleep_seconds="${KUBE_DOWNLOAD_RETRY_MAX_SLEEP_SECONDS:-${DOWNLOAD_RETRY_MAX_SLEEP_SECONDS:-45}}"
  local sleep_seconds

  until curl -fsSL --connect-timeout 10 --max-time 60 "${url}" -o "${out_file}"; do
    if [[ "${n}" -ge "${attempts}" ]]; then
      return 1
    fi
    sleep_seconds="$(compute_backoff_sleep_seconds "${n}" "${base_sleep_seconds}" "${backoff_factor}" "${max_sleep_seconds}")"
    n=$((n + 1))
    sleep "${sleep_seconds}"
  done
}

strict_apt_update() {
  apt-get update -y -o APT::Update::Error-Mode=any
}

configure_apt_proxy() {
  local proxy_url="${1:-}"
  local apt_proxy_conf="/etc/apt/apt.conf.d/95proxy"

  if [[ -n "${proxy_url}" ]]; then
    cat >"${apt_proxy_conf}" <<CFG
Acquire::http::Proxy "${proxy_url}";
Acquire::https::Proxy "${proxy_url}";
CFG
  else
    rm -f "${apt_proxy_conf}"
  fi
}
