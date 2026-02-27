#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f .cluster/admin.conf ]]; then
  echo "Missing .cluster/admin.conf. Run 'make kubeconfig' first." >&2
  exit 1
fi

if [[ "${KUBE_API_LB_ENABLED:-true}" != "true" || "${KUBE_CP_COUNT:-1}" -le 1 ]]; then
  echo "HA kubeconfig requires KUBE_API_LB_ENABLED=true and KUBE_CP_COUNT>1." >&2
  exit 1
fi

endpoint="${KUBE_HA_KUBECONFIG_SERVER:-https://${KUBE_API_LB_IP:-10.30.0.5}:6443}"

awk -v endpoint="${endpoint}" '
  /^[[:space:]]*server:[[:space:]]*https:\/\// && !done {
    print "    server: " endpoint
    done=1
    next
  }
  { print }
  END {
    if (!done) {
      exit 2
    }
  }
' .cluster/admin.conf > .cluster/admin-ha.conf

chmod 600 .cluster/admin-ha.conf
echo "Wrote HA kubeconfig: .cluster/admin-ha.conf (server=${endpoint})"
