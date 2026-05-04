.DEFAULT_GOAL := help

KUBE_CONFIG_YAML ?= config/cluster.yaml
KUBE_GENERATED_MK ?= .generated/cluster.mk
$(shell ./scripts/config/render_env_from_yaml.sh "$(KUBE_CONFIG_YAML)" "$(KUBE_GENERATED_MK)" >/dev/null 2>&1)
-include $(KUBE_GENERATED_MK)
-include config/cluster.env
export
VAGRANT_RUN := ./scripts/vagrant_retry.sh vagrant

.PHONY: help
help:
	@echo "Commands:"
	@echo "- probe-host\t\t: inspect host CPU/memory/provider capabilities"
	@echo "- doctor\t\t: check required tools/plugins for selected provider"
	@echo "- compare-cni\t\t: print CNI tradeoff summary"
	@echo "- cp-status\t\t: show control-plane nodes and etcd leader snapshot"
	@echo "- cp-leader\t\t: show current etcd leader pod/node"
	@echo "- cp-wait NODE=cp2 CP=2\t: wait for control-plane node+etcd stabilization"
	@echo "- hello-workers\t\t: deploy hello workload and verify worker placement"
	@echo "- taint-demo\t\t: demo taint/toleration scheduling behavior"
	@echo "- demo-cleanup\t\t: cleanup demo namespace and demo taints"
	@echo "- bake-box\t\t: bake a local base box (Packer first, Vagrant fallback)"
	@echo "- bake-box-packer\t: bake local base box using Packer"
	@echo "- bake-box-vagrant\t: bake local base box using Vagrant only"
	@echo "- verify-box\t\t: boot-test current box and SSH before full cluster up"
	@echo "- preflight\t\t: host resource/network preflight checks for requested topology"
	@echo "- phase-infra\t\t: bring up infra and control planes only"
	@echo "- phase-workers\t\t: bring up workers (base + join)"
	@echo "- ensure-box\t\t: ensure default local baked box exists"
	@echo "- config-sync\t\t: regenerate .generated/cluster.mk from config/cluster.yaml"
	@echo "- up\t\t\t: bring up cluster and refresh .cluster/admin.conf"
	@echo "- kubeconfig\t\t: fetch kubeconfig to .cluster/admin.conf"
	@echo "- validate\t\t: run post-deploy feature checks"
	@echo "- collect-failures\t: gather node/service/network diagnostics into .cluster/failures"
	@echo "- destroy\t\t: destroy all vagrant nodes"
	@echo "- destroy-strict\t: destroy and assert no residual libvirt domains for this project"
	@echo "- down\t\t\t: alias for destroy"
	@echo "- test\t\t\t: static checks for scripts and Vagrantfile"

.PHONY: probe-host
probe-host:
	./scripts/probe_host.sh

.PHONY: doctor
doctor:
	./scripts/doctor.sh

.PHONY: compare-cni
compare-cni:
	./scripts/compare_cni.sh

.PHONY: cp-status
cp-status:
	./scripts/control_plane_diagnostics.sh status

.PHONY: cp-leader
cp-leader:
	./scripts/control_plane_diagnostics.sh leader

.PHONY: cp-wait
cp-wait:
	test -n "$${NODE}" && test -n "$${CP}" || (echo "Usage: make cp-wait NODE=cp2 CP=2" && exit 1)
	./scripts/wait_control_plane_stable.sh "$${NODE}" "$${CP}"

.PHONY: hello-workers
hello-workers:
	./scripts/workload_placement_demo.sh hello-workers

.PHONY: taint-demo
taint-demo:
	./scripts/workload_placement_demo.sh taint-demo

.PHONY: demo-cleanup
demo-cleanup:
	./scripts/workload_placement_demo.sh cleanup

.PHONY: bake-box
bake-box: config-sync
	if command -v packer >/dev/null 2>&1; then \
		./scripts/bake_packer_box.sh; \
	else \
		echo "packer not found, falling back to Vagrant-only box bake"; \
		./scripts/bake_local_box.sh; \
	fi

.PHONY: bake-box-packer
bake-box-packer: config-sync
	./scripts/bake_packer_box.sh

.PHONY: bake-box-vagrant
bake-box-vagrant: config-sync
	./scripts/bake_local_box.sh

.PHONY: verify-box
verify-box: config-sync ensure-box
	./scripts/verify_box.sh

.PHONY: preflight
preflight: config-sync
	./scripts/preflight.sh

.PHONY: ensure-box
ensure-box: config-sync
	./scripts/ensure_base_box.sh

.PHONY: config-sync
config-sync:
	./scripts/config/render_env_from_yaml.sh "$(KUBE_CONFIG_YAML)" "$(KUBE_GENERATED_MK)"

.PHONY: phase-infra
phase-infra: config-sync ensure-box preflight
	./scripts/run_up_flow.sh infra

.PHONY: phase-workers
phase-workers: config-sync ensure-box preflight
	./scripts/run_up_flow.sh workers

.PHONY: up
up: config-sync ensure-box verify-box preflight
	./scripts/run_up_flow.sh full

.PHONY: kubeconfig
kubeconfig: config-sync
	# Refresh local kubeconfig from cp1 for kubectl against this lab cluster.
	mkdir -p .cluster
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > .cluster/admin.conf
	chmod 600 .cluster/admin.conf

.PHONY: validate
validate: config-sync
	./scripts/validate_cluster.sh

.PHONY: collect-failures
collect-failures: config-sync
	./scripts/collect_failures.sh

.PHONY: destroy
destroy: config-sync
	./scripts/cleanup_all.sh cluster ffreis-k8s-vagrant-lab_

.PHONY: destroy-strict
destroy-strict: config-sync
	STRICT=true ./scripts/cleanup_all.sh cluster ffreis-k8s-vagrant-lab_

.PHONY: down
down: destroy

.PHONY: test
test: config-sync
	./tests/test_static.sh
