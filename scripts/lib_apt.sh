#!/usr/bin/env bash
set -euo pipefail

APT_CACHE_MAX_AGE_SECONDS="${APT_CACHE_MAX_AGE_SECONDS:-21600}"

retry_cmd() {
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

apt_lists_fresh() {
  local newest now age
  newest="$(find /var/lib/apt/lists -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -n1 || true)"
  if [[ -z "${newest}" ]]; then
    return 1
  fi
  now="$(date +%s)"
  age=$((now - ${newest%.*}))
  [[ "${age}" -le "${APT_CACHE_MAX_AGE_SECONDS}" ]]
}

apt_update_if_stale() {
  if apt_lists_fresh; then
    return 0
  fi
  retry_cmd 5 apt-get update -y -o APT::Update::Error-Mode=any
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

pkg_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

install_missing_no_upgrade() {
  local missing=()
  local pkg
  for pkg in "$@"; do
    if ! pkg_installed "${pkg}"; then
      missing+=("${pkg}")
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  apt_update_if_stale
  retry_cmd 5 apt-get install -y --no-upgrade "${missing[@]}"
}
