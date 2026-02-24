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
	@echo "- config-sync\t\t: regenerate .generated/cluster.mk from config/cluster.yaml"
	@echo "- up\t\t\t: bring up cluster and refresh .cluster/admin.conf"
	@echo "- kubeconfig\t\t: fetch kubeconfig to .cluster/admin.conf"
	@echo "- validate\t\t: run post-deploy feature checks"
	@echo "- destroy\t\t: destroy all vagrant nodes"
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

.PHONY: config-sync
config-sync:
	./scripts/config/render_env_from_yaml.sh "$(KUBE_CONFIG_YAML)" "$(KUBE_GENERATED_MK)"

.PHONY: up
up: config-sync
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Prepare fresh local artifact directory used by join/provision steps.
	mkdir -p .cluster
	rm -f .cluster/ready .cluster/failed
	# Start and provision API load balancer first when enabled.
	@echo "Topology: control-planes=$${KUBE_CP_COUNT} workers=$${KUBE_WORKER_COUNT} api-lb=$${KUBE_API_LB_ENABLED}"
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ]; then $(VAGRANT_RUN) up api-lb --provider "$${KUBE_PROVIDER}"; fi
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ]; then $(VAGRANT_RUN) provision api-lb; fi
	# Bootstrap the first control plane (creates join artifacts).
	$(VAGRANT_RUN) up cp1 --provider "$${KUBE_PROVIDER}"
	$(VAGRANT_RUN) provision cp1
	$(VAGRANT_RUN) ssh cp1 -c 'test -f /vagrant/.cluster/ready'
	# Copy join materials from cp1 VM to host workspace for subsequent joins.
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/join.sh' | tr -d '\r' > .cluster/join.sh
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/certificate-key' | tr -d '\r' > .cluster/certificate-key
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/admin.conf' | tr -d '\r' > .cluster/admin.conf
	touch .cluster/ready
	chmod 600 .cluster/join.sh .cluster/certificate-key .cluster/admin.conf
	# Wait for cp1 API/etcd stabilization before starting cp2 join.
	./scripts/wait_control_plane_stable.sh cp1 1
	# Bring up and provision remaining control planes deterministically.
	if [ "$${KUBE_CP_COUNT}" -gt 1 ]; then \
		for i in $$(seq 2 "$${KUBE_CP_COUNT}"); do \
			$(VAGRANT_RUN) up "cp$${i}" --provider "$${KUBE_PROVIDER}"; \
			$(VAGRANT_RUN) provision "cp$${i}"; \
			./scripts/wait_control_plane_stable.sh "cp$${i}" "$${i}"; \
		done; \
	fi
	# Bring up and provision workers deterministically.
	if [ "$${KUBE_WORKER_COUNT}" -gt 0 ]; then \
		for i in $$(seq 1 "$${KUBE_WORKER_COUNT}"); do \
			$(VAGRANT_RUN) up "worker$${i}" --provider "$${KUBE_PROVIDER}"; \
			$(VAGRANT_RUN) provision "worker$${i}"; \
		done; \
	fi
	# Ensure local kubeconfig points at the latest cp1 admin credentials.
	$(MAKE) kubeconfig

.PHONY: kubeconfig
kubeconfig: config-sync
	# Refresh local kubeconfig from cp1 for kubectl against this lab cluster.
	mkdir -p .cluster
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > .cluster/admin.conf
	chmod 600 .cluster/admin.conf

.PHONY: validate
validate: config-sync
	./scripts/validate_cluster.sh

.PHONY: destroy
destroy: config-sync
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Best-effort Vagrant destroy for the LB and all configured machines.
	$(VAGRANT_RUN) destroy -f api-lb || true
	$(VAGRANT_RUN) destroy -f || true
	# Cleanup orphan libvirt domains/volumes; asks before sudo if elevation is required.
	./scripts/libvirt_cleanup.sh ffreis-k8s-vagrant-lab_
	# Clear local state/cache generated by this lab.
	rm -rf .cluster .vagrant .vagrant-nodes.json

.PHONY: test
test: config-sync
	./tests/test_static.sh
