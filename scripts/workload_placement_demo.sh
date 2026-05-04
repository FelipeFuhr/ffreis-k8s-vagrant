#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-hello-workers}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(pwd)/.cluster/admin.conf}"
NAMESPACE="${KUBE_DEMO_NAMESPACE:-k8s-lab-probe}"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "Missing kubeconfig at ${KUBECONFIG_PATH}. Run 'make kubeconfig' first." >&2
  exit 1
fi

kc() {
  KUBECONFIG="${KUBECONFIG_PATH}" kubectl "$@"
}

require_worker() {
  local worker
  worker="$(
    kc get nodes --no-headers \
      | awk '$3 !~ /control-plane/ && $2 ~ /^Ready$/ {print $1; exit}'
  )"
  if [[ -z "${worker}" ]]; then
    echo "No Ready worker node found." >&2
    exit 1
  fi
}

hello_workers() {
  echo "[hello-workers] deploying hello workload pinned to workers"
  kc create namespace "${NAMESPACE}" --dry-run=client -o yaml | kc apply -f -

  kc apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello-workers
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello-workers
  template:
    metadata:
      labels:
        app: hello-workers
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: DoesNotExist
      containers:
      - name: web
        image: nginx:1.27
        ports:
        - containerPort: 80
YAML

  kc -n "${NAMESPACE}" rollout status deploy/hello-workers --timeout=180s
  echo "[hello-workers] pod placement"
  kc -n "${NAMESPACE}" get pods -l app=hello-workers -o wide

  if kc -n "${NAMESPACE}" get pods -l app=hello-workers -o wide --no-headers | awk '{print $7}' | grep -q '^cp[0-9]\+$'; then
    echo "hello-workers landed on a control-plane node unexpectedly" >&2
    exit 1
  fi

  echo "[hello-workers] all replicas are on worker nodes"
}

taint_demo() {
  local worker_node blocked_status tolerated_node
  require_worker

  worker_node="$(
    kc get nodes --no-headers \
      | awk '$3 !~ /control-plane/ && $2 ~ /^Ready$/ {print $1; exit}'
  )"

  echo "[taint-demo] worker selected: ${worker_node}"
  echo "[taint-demo] applying taint lab/demo=block:NoSchedule"
  kc taint nodes "${worker_node}" lab/demo=block:NoSchedule --overwrite
  trap 'kc taint nodes "'"${worker_node}"'" lab/demo:NoSchedule- >/dev/null 2>&1 || true' EXIT

  kc create namespace "${NAMESPACE}" --dry-run=client -o yaml | kc apply -f -

  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: taint-probe-blocked
  namespace: ${NAMESPACE}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${worker_node}
  containers:
  - name: web
    image: nginx:1.27
YAML

  sleep 8
  blocked_status="$(kc -n "${NAMESPACE}" get pod taint-probe-blocked -o jsonpath='{.status.phase}')"
  echo "[taint-demo] taint-probe-blocked status: ${blocked_status}"
  if [[ "${blocked_status}" != "Pending" ]]; then
    echo "Expected taint-probe-blocked to stay Pending due to missing toleration" >&2
    kc -n "${NAMESPACE}" get pod taint-probe-blocked -o wide || true
    exit 1
  fi

  kc apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: taint-probe-tolerated
  namespace: ${NAMESPACE}
spec:
  nodeSelector:
    kubernetes.io/hostname: ${worker_node}
  tolerations:
  - key: lab/demo
    operator: Equal
    value: block
    effect: NoSchedule
  containers:
  - name: web
    image: nginx:1.27
YAML

  kc -n "${NAMESPACE}" wait --for=condition=Ready pod/taint-probe-tolerated --timeout=180s
  tolerated_node="$(kc -n "${NAMESPACE}" get pod taint-probe-tolerated -o jsonpath='{.spec.nodeName}')"
  echo "[taint-demo] taint-probe-tolerated scheduled on: ${tolerated_node}"
  kc -n "${NAMESPACE}" get pods -o wide
  echo "[taint-demo] success: taint blocks non-tolerating pod and allows tolerating pod"
}

cleanup_demo() {
  echo "[cleanup] deleting demo namespace and clearing demo taints"
  kc delete namespace "${NAMESPACE}" --ignore-not-found
  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    kc taint nodes "${node}" lab/demo:NoSchedule- >/dev/null 2>&1 || true
  done < <(kc get nodes -o name | cut -d/ -f2)
}

case "${MODE}" in
  hello-workers)
    hello_workers
    ;;
  taint-demo)
    taint_demo
    ;;
  cleanup)
    cleanup_demo
    ;;
  *)
    echo "Usage: $0 [hello-workers|taint-demo|cleanup]" >&2
    exit 1
    ;;
esac
