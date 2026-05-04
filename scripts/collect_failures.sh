#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/.cluster/failures"
VAGRANT_RUN="${ROOT_DIR}/scripts/vagrant_retry.sh"

mkdir -p "${OUT_DIR}"

collect_from_node() {
  local node="$1"
  "${VAGRANT_RUN}" vagrant ssh "${node}" -c "sudo journalctl -u kubelet -n 200 --no-pager" >"${OUT_DIR}/${node}-kubelet.log" 2>/dev/null || true
  "${VAGRANT_RUN}" vagrant ssh "${node}" -c "sudo journalctl -u containerd -n 200 --no-pager" >"${OUT_DIR}/${node}-containerd.log" 2>/dev/null || true
  "${VAGRANT_RUN}" vagrant ssh "${node}" -c "ip -o -4 addr show; ip route" >"${OUT_DIR}/${node}-network.log" 2>/dev/null || true
}

cd "${ROOT_DIR}"
if [[ -f .vagrant-nodes.json ]]; then
  nodes=$(jq -r '.[].name' .vagrant-nodes.json 2>/dev/null || true)
  for n in ${nodes}; do
    collect_from_node "${n}"
  done
fi

cp -a .cluster/*.log "${OUT_DIR}/" 2>/dev/null || true
cp -a .cluster/failed "${OUT_DIR}/" 2>/dev/null || true

echo "Failure bundle collected at ${OUT_DIR}"
