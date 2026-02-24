#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-config/cluster.yaml}"
OUTPUT_PATH="${2:-.generated/cluster.mk}"

if [[ ! -f "${INPUT_PATH}" ]]; then
  echo "missing config yaml: ${INPUT_PATH}" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT_PATH}")"

ruby - "${INPUT_PATH}" >"${OUTPUT_PATH}" <<'RUBY'
require 'yaml'

input = ARGV[0]
cfg = YAML.load_file(input) || {}

def dig_value(hash, *path)
  path.reduce(hash) do |acc, key|
    break nil unless acc.is_a?(Hash)
    acc[key]
  end
end

def emit(key, value)
  value = '' if value.nil?
  value = value ? 'true' : 'false' if value == true || value == false
  puts "#{key} := #{value}"
end

mappings = {
  'KUBE_CP_COUNT' => ['cluster', 'control_planes'],
  'KUBE_WORKER_COUNT' => ['cluster', 'workers'],
  'KUBE_PROVIDER' => ['provider', 'name'],
  'KUBE_CP_CPUS' => ['resources', 'control_plane', 'cpus'],
  'KUBE_CP_MEMORY' => ['resources', 'control_plane', 'memory'],
  'KUBE_WORKER_CPUS' => ['resources', 'worker', 'cpus'],
  'KUBE_WORKER_MEMORY' => ['resources', 'worker', 'memory'],
  'KUBE_API_LB_CPUS' => ['resources', 'api_lb', 'cpus'],
  'KUBE_API_LB_MEMORY' => ['resources', 'api_lb', 'memory'],
  'KUBE_NETWORK_PREFIX' => ['network', 'prefix'],
  'KUBE_POD_CIDR' => ['network', 'pod_cidr'],
  'KUBE_SERVICE_CIDR' => ['network', 'service_cidr'],
  'KUBE_API_LB_ENABLED' => ['network', 'api_lb', 'enabled'],
  'KUBE_API_LB_IP' => ['network', 'api_lb', 'ip'],
  'KUBE_API_LB_HOSTNAME' => ['network', 'api_lb', 'hostname'],
  'KUBE_VERSION' => ['kubernetes', 'version'],
  'KUBE_CHANNEL' => ['kubernetes', 'channel'],
  'KUBE_CNI' => ['kubernetes', 'cni'],
  'KUBE_CNI_MANIFEST_FLANNEL' => ['kubernetes', 'cni_manifest_flannel'],
  'KUBE_CNI_MANIFEST_CALICO' => ['kubernetes', 'cni_manifest_calico'],
  'KUBE_CNI_MANIFEST_CILIUM' => ['kubernetes', 'cni_manifest_cilium'],
  'KUBE_PAUSE_IMAGE' => ['kubernetes', 'pause_image'],
  'KUBE_BOX' => ['vagrant', 'box'],
  'KUBE_BOX_VERSION' => ['vagrant', 'box_version'],
  'KUBE_CONTAINERD_VERSION' => ['packages', 'containerd'],
  'KUBE_HAPROXY_VERSION' => ['packages', 'haproxy'],
  'KUBE_APT_PROXY' => ['apt', 'proxy'],
  'KUBE_SSH_PUBKEY' => ['ssh', 'public_key'],
  'KUBE_JOIN_MAX_WAIT_SECONDS' => ['tuning', 'join_max_wait_seconds'],
  'KUBE_JOIN_POLL_SECONDS' => ['tuning', 'join_poll_seconds'],
  'KUBE_CP_JOIN_WARN_SHOW_LIMIT' => ['tuning', 'cp_join_warn_show_limit'],
  'KUBE_CP_JOIN_WARN_REPORT_INTERVAL_SECONDS' => ['tuning', 'cp_join_warn_report_interval_seconds'],
  'KUBE_CP_JOIN_WARN_REPORT_EVERY' => ['tuning', 'cp_join_warn_report_every'],
  'KUBE_CP_JOIN_RETRY_ATTEMPTS' => ['tuning', 'cp_join_retry_attempts'],
  'KUBE_CP_JOIN_RETRY_SLEEP_SECONDS' => ['tuning', 'cp_join_retry_sleep_seconds'],
  'KUBE_CP_JOIN_RETRY_BACKOFF_FACTOR' => ['tuning', 'cp_join_retry_backoff_factor'],
  'KUBE_CP_JOIN_RETRY_MAX_SLEEP_SECONDS' => ['tuning', 'cp_join_retry_max_sleep_seconds'],
  'KUBE_CP_JOIN_RETRY_MAX_TOTAL_SECONDS' => ['tuning', 'cp_join_retry_max_total_seconds'],
  'KUBE_CP_STABILIZE_TIMEOUT_SECONDS' => ['tuning', 'cp_stabilize_timeout_seconds'],
  'KUBE_CP_STABILIZE_POLL_SECONDS' => ['tuning', 'cp_stabilize_poll_seconds'],
  'KUBE_VALIDATE_READY_TIMEOUT_SECONDS' => ['tuning', 'validate_ready_timeout_seconds'],
  'KUBE_VALIDATE_READY_POLL_SECONDS' => ['tuning', 'validate_ready_poll_seconds'],
  'KUBE_VAGRANT_RETRY_ATTEMPTS' => ['tuning', 'vagrant_retry_attempts'],
  'KUBE_VAGRANT_RETRY_SLEEP_SECONDS' => ['tuning', 'vagrant_retry_sleep_seconds'],
  'KUBE_VAGRANT_RETRY_BACKOFF_FACTOR' => ['tuning', 'vagrant_retry_backoff_factor'],
  'KUBE_VAGRANT_RETRY_MAX_SLEEP_SECONDS' => ['tuning', 'vagrant_retry_max_sleep_seconds'],
  'KUBE_VAGRANT_RETRY_MAX_TOTAL_SECONDS' => ['tuning', 'vagrant_retry_max_total_seconds']
}

puts '# Generated from config/cluster.yaml. Do not edit directly.'
mappings.each do |key, path|
  emit(key, dig_value(cfg, *path))
end
RUBY
