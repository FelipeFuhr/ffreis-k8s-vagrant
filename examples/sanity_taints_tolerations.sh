#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ -f config/cluster.env ]]; then
  # shellcheck disable=SC1091
  source config/cluster.env
fi

SANITY_NS="${SANITY_NS:-sanity-taints}"
TAINT_KEY="${TAINT_KEY:-sanity}"
TAINT_VALUE="${TAINT_VALUE:-demo}"
TAINT_EFFECT="${TAINT_EFFECT:-NoSchedule}"
MAX_WORKERS="${MAX_WORKERS:-2}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180s}"

retry() {
  ./scripts/vagrant_retry.sh "$@"
}

kubectl_cp1() {
  retry vagrant ssh cp1 -c \
    "sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl $*"
}

cleanup() {
  local node
  set +e
  for node in "${TARGET_WORKERS[@]:-}"; do
    kubectl_cp1 "taint nodes ${node} ${TAINT_KEY}- >/dev/null 2>&1 || true"
  done
  kubectl_cp1 "delete ns ${SANITY_NS} --wait=false >/dev/null 2>&1 || true"
}

declare -a TARGET_WORKERS=()
trap cleanup EXIT

echo "Discovering worker nodes..."
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  TARGET_WORKERS+=("${line#node/}")
done < <(
  kubectl_cp1 "get nodes -l '!node-role.kubernetes.io/control-plane' -o name" \
    | tr -d '\r'
)

if [[ "${#TARGET_WORKERS[@]}" -eq 0 ]]; then
  echo "No worker nodes found."
  exit 1
fi

if [[ "${#TARGET_WORKERS[@]}" -gt "${MAX_WORKERS}" ]]; then
  TARGET_WORKERS=("${TARGET_WORKERS[@]:0:${MAX_WORKERS}}")
fi

echo "Selected workers: ${TARGET_WORKERS[*]}"
echo "Applying temporary taint ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}..."
for node in "${TARGET_WORKERS[@]}"; do
  kubectl_cp1 "taint nodes ${node} ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT} --overwrite"
done

kubectl_cp1 "create ns ${SANITY_NS} >/dev/null 2>&1 || true"

echo "Creating hello-world pods with matching tolerations..."
for node in "${TARGET_WORKERS[@]}"; do
  pod_name="hello-${node}"
  cat <<EOF | kubectl_cp1 "apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${SANITY_NS}
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${node}
  tolerations:
  - key: "${TAINT_KEY}"
    operator: "Equal"
    value: "${TAINT_VALUE}"
    effect: "${TAINT_EFFECT}"
  containers:
  - name: hello
    image: busybox:1.36
    command: ["sh", "-c", "echo hello-world from ${node}; sleep 30"]
EOF
done

echo "Waiting for pods to become Ready..."
for node in "${TARGET_WORKERS[@]}"; do
  pod_name="hello-${node}"
  kubectl_cp1 "wait -n ${SANITY_NS} --for=condition=Ready pod/${pod_name} --timeout=${WAIT_TIMEOUT}"
done

echo "Validating logs..."
for node in "${TARGET_WORKERS[@]}"; do
  pod_name="hello-${node}"
  log_out="$(kubectl_cp1 "logs -n ${SANITY_NS} ${pod_name}" | tr -d '\r')"
  if [[ "${log_out}" != *"hello-world"* ]]; then
    echo "Expected hello-world log not found in ${pod_name}"
    exit 1
  fi
  echo "[OK] ${pod_name}: ${log_out}"
done

echo "Sanity test passed. Cleaning up resources and taints..."
