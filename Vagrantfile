# frozen_string_literal: true

require 'json'
require 'yaml'

config_yaml_path = ENV.fetch('KUBE_CONFIG_YAML', 'config/cluster.yaml')
config_yaml = File.exist?(config_yaml_path) ? (YAML.load_file(config_yaml_path) || {}) : {}

dig_cfg = lambda do |path|
  path.reduce(config_yaml) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
end

cfg_str = lambda do |env_key, path, default|
  env_val = ENV[env_key]
  return env_val unless env_val.nil? || env_val.empty?

  cfg_val = dig_cfg.call(path)
  return default if cfg_val.nil?

  cfg_val.to_s
end

cp_count = Integer(cfg_str.call('KUBE_CP_COUNT', %w[cluster control_planes], '1'))
worker_count = Integer(cfg_str.call('KUBE_WORKER_COUNT', %w[cluster workers], '2'))
provider = cfg_str.call('KUBE_PROVIDER', %w[provider name], 'libvirt')
box = cfg_str.call('KUBE_BOX', %w[vagrant box], 'bento/ubuntu-24.04')
box_version = cfg_str.call('KUBE_BOX_VERSION', %w[vagrant box_version], '')
network_prefix = cfg_str.call('KUBE_NETWORK_PREFIX', %w[network prefix], '10.30.0')
api_lb_enabled = cfg_str.call('KUBE_API_LB_ENABLED', %w[network api_lb enabled], 'true') == 'true'
api_lb_ip = cfg_str.call('KUBE_API_LB_IP', %w[network api_lb ip], "#{network_prefix}.5")
api_lb_hostname = cfg_str.call('KUBE_API_LB_HOSTNAME', %w[network api_lb hostname], 'k8s-api.local')
cp_cpus = Integer(cfg_str.call('KUBE_CP_CPUS', %w[resources control_plane cpus], '2'))
cp_memory = Integer(cfg_str.call('KUBE_CP_MEMORY', %w[resources control_plane memory], '4096'))
worker_cpus = Integer(cfg_str.call('KUBE_WORKER_CPUS', %w[resources worker cpus], '2'))
worker_memory = Integer(cfg_str.call('KUBE_WORKER_MEMORY', %w[resources worker memory], '3072'))
api_lb_cpus = Integer(cfg_str.call('KUBE_API_LB_CPUS', %w[resources api_lb cpus], '1'))
api_lb_memory = Integer(cfg_str.call('KUBE_API_LB_MEMORY', %w[resources api_lb memory], '1024'))
ssh_pubkey = cfg_str.call('KUBE_SSH_PUBKEY', %w[ssh public_key], '')
kube_version = cfg_str.call('KUBE_VERSION', %w[kubernetes version], '1.30.6-1.1')
kube_channel = cfg_str.call('KUBE_CHANNEL', %w[kubernetes channel], 'v1.30')
kube_cni = cfg_str.call('KUBE_CNI', %w[kubernetes cni], 'flannel')
kube_cni_manifest_flannel = cfg_str.call('KUBE_CNI_MANIFEST_FLANNEL', %w[kubernetes cni_manifest_flannel], 'https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml')
kube_cni_manifest_calico = cfg_str.call('KUBE_CNI_MANIFEST_CALICO', %w[kubernetes cni_manifest_calico], 'https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml')
kube_cni_manifest_cilium = cfg_str.call('KUBE_CNI_MANIFEST_CILIUM', %w[kubernetes cni_manifest_cilium], 'https://raw.githubusercontent.com/cilium/cilium/v1.16.5/install/kubernetes/quick-install.yaml')
kube_pause_image = cfg_str.call('KUBE_PAUSE_IMAGE', %w[kubernetes pause_image], 'registry.k8s.io/pause:3.9')
containerd_version = cfg_str.call('KUBE_CONTAINERD_VERSION', %w[packages containerd], '')
haproxy_version = cfg_str.call('KUBE_HAPROXY_VERSION', %w[packages haproxy], '')
apt_proxy = cfg_str.call('KUBE_APT_PROXY', %w[apt proxy], '')
kube_pod_cidr = cfg_str.call('KUBE_POD_CIDR', %w[network pod_cidr], '10.244.0.0/16')
kube_service_cidr = cfg_str.call('KUBE_SERVICE_CIDR', %w[network service_cidr], '10.96.0.0/12')
control_plane_endpoint = if api_lb_enabled
                           "#{api_lb_ip}:6443"
                         else
                           "#{network_prefix}.11:6443"
                         end

if cp_count < 1
  raise 'KUBE_CP_COUNT must be >= 1'
end

nodes = []

if api_lb_enabled
  nodes << {
    name: 'api-lb',
    role: 'api-lb',
    ip: api_lb_ip,
    cpus: api_lb_cpus,
    memory: api_lb_memory
  }
end

(1..cp_count).each do |index|
  nodes << {
    name: "cp#{index}",
    role: 'control-plane',
    ip: "#{network_prefix}.#{10 + index}",
    cpus: cp_cpus,
    memory: cp_memory
  }
end

(1..worker_count).each do |index|
  nodes << {
    name: "worker#{index}",
    role: 'worker',
    ip: "#{network_prefix}.#{100 + index}",
    cpus: worker_cpus,
    memory: worker_memory
  }
end

File.write('.vagrant-nodes.json', JSON.pretty_generate(nodes))

Vagrant.configure('2') do |config|
  config.vm.box = box
  config.vm.box_version = box_version unless box_version.empty?
  config.vm.synced_folder '.', '/vagrant', type: 'rsync'

  nodes.each do |node|
    config.vm.define node[:name] do |machine|
      machine.vm.hostname = node[:name]
      machine.vm.network 'private_network', ip: node[:ip]

      machine.vm.provider provider do |provider_cfg|
        provider_cfg.cpus = node[:cpus]
        provider_cfg.memory = node[:memory]
      end

      if node[:role] == 'api-lb'
        machine.vm.provision 'shell', path: 'scripts/05_api_lb.sh', env: {
          'NODE_NAME' => node[:name],
          'CP_COUNT' => cp_count.to_s,
          'NETWORK_PREFIX' => network_prefix,
          'API_LB_HOSTNAME' => api_lb_hostname,
          'API_LB_IP' => api_lb_ip,
          'KUBE_HAPROXY_VERSION' => haproxy_version,
          'KUBE_APT_PROXY' => apt_proxy
        }
      else
        machine.vm.provision 'shell', path: 'scripts/00_common.sh', env: {
          'NODE_ROLE' => node[:role],
          'NODE_NAME' => node[:name],
          'CP_COUNT' => cp_count.to_s,
          'WORKER_COUNT' => worker_count.to_s,
          'SSH_PUBKEY' => ssh_pubkey,
          'KUBE_VERSION' => kube_version,
          'KUBE_CHANNEL' => kube_channel,
          'KUBE_CONTAINERD_VERSION' => containerd_version,
          'KUBE_PAUSE_IMAGE' => kube_pause_image,
          'KUBE_APT_PROXY' => apt_proxy
        }
      end

      if node[:role] == 'api-lb'
        # api-lb is not a Kubernetes node; it only fronts the API server.
      elsif node[:name] == 'cp1'
        machine.vm.provision 'shell', path: 'scripts/10_init_control_plane.sh', env: {
          'CP1_IP' => "#{network_prefix}.11",
          'CONTROL_PLANE_ENDPOINT' => control_plane_endpoint,
          'CONTROL_PLANE_ENDPOINT_HOST' => api_lb_enabled ? api_lb_hostname : 'cp1',
          'KUBE_POD_CIDR' => kube_pod_cidr,
          'KUBE_SERVICE_CIDR' => kube_service_cidr,
          'KUBE_CNI' => kube_cni,
          'KUBE_CNI_MANIFEST_FLANNEL' => kube_cni_manifest_flannel,
          'KUBE_CNI_MANIFEST_CALICO' => kube_cni_manifest_calico,
          'KUBE_CNI_MANIFEST_CILIUM' => kube_cni_manifest_cilium,
          'KUBE_VERSION' => kube_version
        }
      elsif node[:role] == 'control-plane'
        machine.vm.provision 'shell', path: 'scripts/20_join_control_plane.sh'
      elsif node[:role] == 'worker'
        machine.vm.provision 'shell', path: 'scripts/30_join_worker.sh'
      end
    end
  end
end
