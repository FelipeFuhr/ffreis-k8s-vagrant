.DEFAULT_GOAL := help

-include config/cluster.env
export
VAGRANT_RUN := ./scripts/vagrant_retry.sh vagrant
PROJECT_LIBVIRT_PREFIX := $(shell basename "$(CURDIR)" | tr -cd '[:alnum:]_-')_
LEGACY_LIBVIRT_PREFIX := ffreis-k8s-vagrant-lab_

.PHONY: help
help:
	@echo "Commands:"
	@echo "- probe-host\t\t: inspect host CPU/memory/provider capabilities"
	@echo "- doctor\t\t: check required tools/plugins for selected provider"
	@echo "- compare-cni\t\t: print CNI tradeoff summary"
	@echo "- cp-connectivity\t: check control-plane connectivity (cp1..cpN)"
	@echo "- cp-failover\t\t: down/up one control-plane node and verify leader failover"
	@echo "- sanity-taints\t\t: taints/tolerations hello-world sanity test on workers"
	@echo "- up\t\t\t: bring up cluster and refresh .cluster/admin.conf"
	@echo "- kubeconfig\t\t: fetch kubeconfig to .cluster/admin.conf"
	@echo "- validate\t\t: run post-deploy feature checks"
	@echo "- destroy\t\t: destroy all vagrant nodes"
	@echo "- test-examples\t\t: run example script self-tests"
	@echo "- test\t\t\t: static checks plus example self-tests"

.PHONY: probe-host
probe-host:
	./scripts/probe_host.sh

.PHONY: doctor
doctor:
	./scripts/doctor.sh

.PHONY: compare-cni
compare-cni:
	./scripts/compare_cni.sh

.PHONY: cp-connectivity
cp-connectivity:
	./examples/check_control_plane_connectivity.sh

.PHONY: cp-failover
cp-failover:
	./examples/test_control_plane_failover.sh

.PHONY: sanity-taints
sanity-taints:
	./examples/sanity_taints_tolerations.sh

.PHONY: up
up:
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Prepare fresh local artifact directory used by join/provision steps.
	mkdir -p .cluster
	rm -f .cluster/ready .cluster/failed
	# Start and provision API load balancer first when enabled.
	@echo "Topology: control-planes=$${KUBE_CP_COUNT} workers=$${KUBE_WORKER_COUNT} external-etcd=$${KUBE_ETCD_COUNT:-3} api-lb=$${KUBE_API_LB_ENABLED}"
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ]; then $(VAGRANT_RUN) up api-lb --provider "$${KUBE_PROVIDER}" --no-provision; fi
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ]; then $(VAGRANT_RUN) provision api-lb; fi
	# Bootstrap dedicated etcd nodes before cp1.
	set -e; \
	for i in $$(seq 1 "$${KUBE_ETCD_COUNT:-3}"); do \
		$(VAGRANT_RUN) up "etcd$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
		$(VAGRANT_RUN) provision "etcd$${i}"; \
	done
	./scripts/wait_external_etcd_cluster.sh
	# Bootstrap the first control plane (creates join artifacts).
	$(VAGRANT_RUN) up cp1 --provider "$${KUBE_PROVIDER}" --no-provision
	$(VAGRANT_RUN) provision cp1
	./scripts/wait_cp_api_ready.sh
	./scripts/wait_external_etcd_cluster.sh
	$(VAGRANT_RUN) ssh cp1 -c 'test -f /vagrant/.cluster/ready'
	# Copy join materials from cp1 VM to host workspace for subsequent joins.
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/join.sh' | tr -d '\r' > .cluster/join.sh
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/certificate-key' | tr -d '\r' > .cluster/certificate-key
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /vagrant/.cluster/admin.conf' | tr -d '\r' > .cluster/admin.conf
	$(VAGRANT_RUN) ssh cp1 -c 'sudo base64 -w0 /vagrant/.cluster/pki-control-plane.tgz' | base64 -d > .cluster/pki-control-plane.tgz
	# Validate control-plane PKI artifact integrity before cp2+ joins.
	tar -tzf .cluster/pki-control-plane.tgz >/dev/null
	expected_hash="$$( $(VAGRANT_RUN) ssh cp1 -c 'sudo sha256sum /vagrant/.cluster/pki-control-plane.tgz | cut -d" " -f1' | tr -d '\r' )"; \
	actual_hash="$$(sha256sum .cluster/pki-control-plane.tgz | cut -d' ' -f1)"; \
	if [ "$${actual_hash}" != "$${expected_hash}" ]; then \
		echo "PKI artifact checksum mismatch: expected=$${expected_hash} actual=$${actual_hash}" >&2; \
		exit 1; \
	fi
	touch .cluster/ready
	chmod 600 .cluster/join.sh .cluster/certificate-key .cluster/admin.conf .cluster/pki-control-plane.tgz
	# Bring up and provision remaining control planes deterministically.
	if [ "$${KUBE_CP_COUNT}" -gt 1 ]; then \
		set -e; \
		for i in $$(seq 2 "$${KUBE_CP_COUNT}"); do \
			./scripts/wait_cp_api_ready.sh; \
			./scripts/wait_external_etcd_cluster.sh; \
			$(VAGRANT_RUN) up "cp$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
			$(VAGRANT_RUN) provision "cp$${i}"; \
			./scripts/wait_cp_api_ready.sh; \
			./scripts/wait_external_etcd_cluster.sh; \
		done; \
	fi
	# Bring up and provision workers deterministically.
	if [ "$${KUBE_WORKER_COUNT}" -gt 0 ]; then \
		set -e; \
		for i in $$(seq 1 "$${KUBE_WORKER_COUNT}"); do \
			$(VAGRANT_RUN) up "worker$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
			$(VAGRANT_RUN) provision "worker$${i}"; \
		done; \
	fi
	# Ensure local kubeconfig points at the latest cp1 admin credentials.
	$(MAKE) kubeconfig

.PHONY: kubeconfig
kubeconfig:
	# Refresh local kubeconfig from cp1 for kubectl against this lab cluster.
	mkdir -p .cluster
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > .cluster/admin.conf
	chmod 600 .cluster/admin.conf

.PHONY: validate
validate:
	./scripts/validate_cluster.sh

.PHONY: destroy
destroy:
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Best-effort Vagrant destroy for the LB and all configured machines.
	$(VAGRANT_RUN) destroy -f api-lb || true
	$(VAGRANT_RUN) destroy -f || true
	# Cleanup orphan libvirt domains/volumes; asks before sudo if elevation is required.
	./scripts/libvirt_cleanup.sh "$(PROJECT_LIBVIRT_PREFIX)"
	# Backward-compat cleanup for older project prefix naming.
	./scripts/libvirt_cleanup.sh "$(LEGACY_LIBVIRT_PREFIX)"
	# Clear local state/cache generated by this lab.
	rm -rf .cluster .vagrant .vagrant-nodes.json

.PHONY: test
test:
	./tests/test_static.sh
	./tests/test_examples.sh

.PHONY: test-examples
test-examples:
	./tests/test_examples.sh
