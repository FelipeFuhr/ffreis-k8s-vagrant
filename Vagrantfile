# frozen_string_literal: true

require 'json'
require 'yaml'

cp_count = Integer(ENV.fetch('KUBE_CP_COUNT', '3'))
worker_count = Integer(ENV.fetch('KUBE_WORKER_COUNT', '2'))
etcd_count = Integer(ENV.fetch('KUBE_ETCD_COUNT', '3'))
provider = ENV.fetch('KUBE_PROVIDER', 'libvirt')
box = ENV.fetch('KUBE_BOX', 'bento/ubuntu-24.04')
network_prefix = ENV.fetch('KUBE_NETWORK_PREFIX', '10.30.0')
api_lb_requested = ENV.fetch('KUBE_API_LB_ENABLED', 'true') == 'true'
api_lb_enabled = api_lb_requested && cp_count > 1
api_lb_ip = ENV.fetch('KUBE_API_LB_IP', "#{network_prefix}.5")
api_lb_hostname = ENV.fetch('KUBE_API_LB_HOSTNAME', 'k8s-api.local')
cp_cpus = Integer(ENV.fetch('KUBE_CP_CPUS', '2'))
cp_memory = Integer(ENV.fetch('KUBE_CP_MEMORY', '2048'))
worker_cpus = Integer(ENV.fetch('KUBE_WORKER_CPUS', '1'))
worker_memory = Integer(ENV.fetch('KUBE_WORKER_MEMORY', '1024'))
api_lb_cpus = Integer(ENV.fetch('KUBE_API_LB_CPUS', '1'))
api_lb_memory = Integer(ENV.fetch('KUBE_API_LB_MEMORY', '512'))
etcd_cpus = Integer(ENV.fetch('KUBE_ETCD_CPUS', '1'))
etcd_memory = Integer(ENV.fetch('KUBE_ETCD_MEMORY', '1024'))
etcd_version = ENV.fetch('KUBE_ETCD_VERSION', '3.5.15')
etcd_reinit_on_provision = ENV.fetch('ETCD_REINIT_ON_PROVISION', 'true')
etcd_auto_recover_on_failure = ENV.fetch('ETCD_AUTO_RECOVER_ON_FAILURE', 'true')
ssh_pubkey = ENV.fetch('KUBE_SSH_PUBKEY', '')
flannel_version = ENV.fetch('KUBE_FLANNEL_VERSION', 'v0.25.7')
wait_report_interval_seconds = ENV.fetch('WAIT_REPORT_INTERVAL_SECONDS', '60')
cp_join_max_attempts = ENV.fetch('CP_JOIN_MAX_ATTEMPTS', '8')
cp_join_base_backoff_seconds = ENV.fetch('CP_JOIN_BASE_BACKOFF_SECONDS', '60')
cp_join_max_backoff_seconds = ENV.fetch('CP_JOIN_MAX_BACKOFF_SECONDS', '240')
etcd_warn_show_limit = ENV.fetch('ETCD_WARN_SHOW_LIMIT', '1')
etcd_warn_report_interval_seconds = ENV.fetch('ETCD_WARN_REPORT_INTERVAL_SECONDS', '90')
apt_cache_max_age_seconds = ENV.fetch('APT_CACHE_MAX_AGE_SECONDS', '21600')
node_inventory_file = ENV.fetch('NODE_INVENTORY_FILE', '').strip
control_plane_endpoint = if api_lb_enabled
                           "#{api_lb_ip}:6443"
                         else
                           "#{network_prefix}.11:6443"
                         end

if cp_count < 1
  raise 'KUBE_CP_COUNT must be >= 1'
end

if etcd_count < 3
  raise 'KUBE_ETCD_COUNT must be >= 3'
end

nodes = []
if !node_inventory_file.empty?
  raw_inventory = YAML.safe_load(File.read(node_inventory_file))
  raw_nodes = raw_inventory.is_a?(Hash) ? raw_inventory['nodes'] : raw_inventory
  raise 'NODE_INVENTORY_FILE must contain a top-level nodes list' unless raw_nodes.is_a?(Array)

  role_map = {
    'control-plane' => 'control-plane',
    'worker' => 'worker',
    'etcd' => 'etcd',
    'api-lb' => 'api-lb'
  }
  nodes = raw_nodes.map do |node|
    role = role_map.fetch(node['role']) { raise "Unsupported role '#{node['role']}' in NODE_INVENTORY_FILE" }
    {
      name: node.fetch('name'),
      role: role,
      ip: node.fetch('ip'),
      cpus: Integer(node.fetch('cpu')),
      memory: Integer(node.fetch('memory_mb'))
    }
  end
else
  if api_lb_enabled
    nodes << {
      name: 'api-lb',
      role: 'api-lb',
      ip: api_lb_ip,
      cpus: api_lb_cpus,
      memory: api_lb_memory
    }
  end

  etcd_nodes = []
  (1..etcd_count).each do |index|
    etcd_nodes << {
      name: "etcd#{index}",
      role: 'etcd',
      ip: "#{network_prefix}.#{20 + index}",
      cpus: etcd_cpus,
      memory: etcd_memory
    }
  end
  nodes.concat(etcd_nodes)

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
end

etcd_nodes = nodes.select { |node| node[:role] == 'etcd' }
control_plane_nodes = nodes.select { |node| node[:role] == 'control-plane' }
raise 'NODE_INVENTORY_FILE must define at least one control-plane node' if control_plane_nodes.empty?
raise 'NODE_INVENTORY_FILE must define at least three etcd nodes' if etcd_nodes.size < 3
primary_control_plane = control_plane_nodes.first
cp_count = control_plane_nodes.size

resolved_api_lb = nodes.find { |node| node[:role] == 'api-lb' }
control_plane_endpoint = if resolved_api_lb
                           "#{resolved_api_lb[:ip]}:6443"
                         else
                           "#{primary_control_plane[:ip]}:6443"
                         end

external_etcd_endpoints = etcd_nodes.map { |node| "http://#{node[:ip]}:2379" }.join(',')
external_etcd_initial_cluster = etcd_nodes.map { |node| "#{node[:name]}=http://#{node[:ip]}:2380" }.join(',')

File.write('.vagrant-nodes.json', JSON.pretty_generate(nodes))

Vagrant.configure('2') do |config|
  config.vm.box = box
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
          'APT_CACHE_MAX_AGE_SECONDS' => apt_cache_max_age_seconds
        }
      elsif node[:role] == 'etcd'
        # external etcd nodes have dedicated etcd provisioning only.
      else
        machine.vm.provision 'shell', path: 'scripts/00_common.sh', env: {
          'NODE_ROLE' => node[:role],
          'NODE_NAME' => node[:name],
          'CP_COUNT' => cp_count.to_s,
          'WORKER_COUNT' => worker_count.to_s,
          'SSH_PUBKEY' => ssh_pubkey,
          'APT_CACHE_MAX_AGE_SECONDS' => apt_cache_max_age_seconds
        }
      end

      if node[:role] == 'api-lb'
        # api-lb is not a Kubernetes node; it only fronts the API server.
      elsif node[:role] == 'etcd'
        machine.vm.provision 'shell', path: 'scripts/15_init_external_etcd.sh', env: {
          'ETCD_NAME' => node[:name],
          'ETCD_IP' => node[:ip],
          'ETCD_INITIAL_CLUSTER' => external_etcd_initial_cluster,
          'ETCD_VERSION' => etcd_version,
          'ETCD_REINIT_ON_PROVISION' => etcd_reinit_on_provision,
          'ETCD_AUTO_RECOVER_ON_FAILURE' => etcd_auto_recover_on_failure,
          'WAIT_REPORT_INTERVAL_SECONDS' => wait_report_interval_seconds,
          'APT_CACHE_MAX_AGE_SECONDS' => apt_cache_max_age_seconds
        }
      elsif node[:name] == primary_control_plane[:name]
        machine.vm.provision 'shell', path: 'scripts/10_init_control_plane.sh', env: {
          'CP1_IP' => primary_control_plane[:ip],
          'CONTROL_PLANE_ENDPOINT' => control_plane_endpoint,
          'CONTROL_PLANE_ENDPOINT_HOST' => resolved_api_lb ? api_lb_hostname : primary_control_plane[:name],
          'KUBE_FLANNEL_VERSION' => flannel_version,
          'WAIT_REPORT_INTERVAL_SECONDS' => wait_report_interval_seconds,
          'EXTERNAL_ETCD_ENDPOINTS' => external_etcd_endpoints
        }
      elsif node[:role] == 'control-plane'
        machine.vm.provision 'shell', path: 'scripts/20_join_control_plane.sh', env: {
          'WAIT_REPORT_INTERVAL_SECONDS' => wait_report_interval_seconds,
          'CP_JOIN_MAX_ATTEMPTS' => cp_join_max_attempts,
          'CP_JOIN_BASE_BACKOFF_SECONDS' => cp_join_base_backoff_seconds,
          'CP_JOIN_MAX_BACKOFF_SECONDS' => cp_join_max_backoff_seconds,
          'EXTERNAL_ETCD_ENDPOINTS' => external_etcd_endpoints,
          'ETCD_WARN_SHOW_LIMIT' => etcd_warn_show_limit,
          'ETCD_WARN_REPORT_INTERVAL_SECONDS' => etcd_warn_report_interval_seconds
        }
      elsif node[:role] == 'worker'
        machine.vm.provision 'shell', path: 'scripts/30_join_worker.sh', env: {
          'WAIT_REPORT_INTERVAL_SECONDS' => wait_report_interval_seconds
        }
      end
    end
  end
end
