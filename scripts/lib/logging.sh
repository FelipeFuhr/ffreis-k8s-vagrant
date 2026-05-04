#!/usr/bin/env bash

log() {
  local node_name
  node_name="${NODE_NAME:-$(hostname -s)}"
  printf '[%s] %s\n' "${node_name}" "$*"
}
