.DEFAULT_GOAL := help

-include config/cluster.env
AUTO_CLEANUP_ON_FAILURE ?= true
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
	@echo "- etcd-connectivity\t: check external etcd endpoint + peer connectivity"
	@echo "- cp-connectivity\t: check control-plane connectivity (cp1..cpN)"
	@echo "- cp-failover\t\t: down/up one control-plane node and verify leader failover"
	@echo "- sanity-taints\t\t: taints/tolerations hello-world sanity test on workers"
	@echo "- ssh-cp N=1\t\t: interactive SSH into control-plane cpN"
	@echo "- ssh-worker N=1\t\t: interactive SSH into workerN"
	@echo "- ssh-cps CMD='...'\t: run command on all control planes (default: hostname -f)"
	@echo "- ssh-workers CMD='...'\t: run command on all workers (default: hostname -f)"
	@echo "- up-etcd\t\t: bring up/provision etcd tier only, then wait for quorum"
	@echo "- up-cp1\t\t: bring up/provision first control-plane only"
	@echo "- up-cps\t\t: bring up/provision remaining control planes (cp2..cpN)"
	@echo "- up-workers\t\t: bring up/provision all workers"
	@echo "- up-node NODE=name\t: bring up a single node without provision"
	@echo "- provision-node NODE=name\t: provision a single node"
	@echo "- up\t\t\t: bring up cluster and refresh .cluster/admin.conf (auto-destroy on failure by default)"
	@echo "  AUTO_CLEANUP_ON_FAILURE=true|false"
	@echo "- kubeconfig\t\t: fetch kubeconfig to .cluster/admin.conf"
	@echo "- kubeconfig-ha\t\t: build HA kubeconfig via api-lb at .cluster/admin-ha.conf"
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

.PHONY: etcd-connectivity
etcd-connectivity:
	./examples/check_etcd_connectivity.sh

.PHONY: cp-connectivity
cp-connectivity:
	./examples/check_control_plane_connectivity.sh

.PHONY: cp-failover
cp-failover:
	./examples/test_control_plane_failover.sh

.PHONY: sanity-taints
sanity-taints:
	./examples/sanity_taints_tolerations.sh

.PHONY: ssh-cp
ssh-cp:
	@if [ -z "$(N)" ]; then echo "Usage: make ssh-cp N=1"; exit 1; fi
	$(VAGRANT_RUN) ssh "cp$(N)"

.PHONY: ssh-worker
ssh-worker:
	@if [ -z "$(N)" ]; then echo "Usage: make ssh-worker N=1"; exit 1; fi
	$(VAGRANT_RUN) ssh "worker$(N)"

.PHONY: ssh-cps
ssh-cps:
	@cmd='$(if $(strip $(CMD)),$(CMD),hostname -f)'; \
	for i in $$(seq 1 "$${KUBE_CP_COUNT:-1}"); do \
		echo "== cp$${i} =="; \
		$(VAGRANT_RUN) ssh "cp$${i}" -c "$${cmd}"; \
	done

.PHONY: ssh-workers
ssh-workers:
	@if [ "$${KUBE_WORKER_COUNT:-0}" -eq 0 ]; then echo "No workers configured (KUBE_WORKER_COUNT=0)."; exit 0; fi
	@cmd='$(if $(strip $(CMD)),$(CMD),hostname -f)'; \
	for i in $$(seq 1 "$${KUBE_WORKER_COUNT:-0}"); do \
		echo "== worker$${i} =="; \
		$(VAGRANT_RUN) ssh "worker$${i}" -c "$${cmd}"; \
	done

.PHONY: up-node
up-node:
	@if [ -z "$(NODE)" ]; then echo "Usage: make up-node NODE=cp1|worker1|etcd1|api-lb"; exit 1; fi
	$(VAGRANT_RUN) up "$(NODE)" --provider "$${KUBE_PROVIDER}" --no-provision

.PHONY: provision-node
provision-node:
	@if [ -z "$(NODE)" ]; then echo "Usage: make provision-node NODE=cp1|worker1|etcd1|api-lb"; exit 1; fi
	$(VAGRANT_RUN) provision "$(NODE)"

.PHONY: up-etcd
up-etcd:
	set -e; \
	for i in $$(seq 1 "$${KUBE_ETCD_COUNT:-3}"); do \
		$(VAGRANT_RUN) up "etcd$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
		$(VAGRANT_RUN) provision "etcd$${i}"; \
	done
	./scripts/wait_external_etcd_cluster.sh

.PHONY: up-cp1
up-cp1:
	$(VAGRANT_RUN) up cp1 --provider "$${KUBE_PROVIDER}" --no-provision
	$(VAGRANT_RUN) provision cp1
	./scripts/wait_cp_api_ready.sh

.PHONY: up-cps
up-cps:
	@if [ "$${KUBE_CP_COUNT:-1}" -le 1 ]; then echo "KUBE_CP_COUNT<=1, no additional control planes."; exit 0; fi
	set -e; \
	for i in $$(seq 2 "$${KUBE_CP_COUNT}"); do \
		./scripts/wait_cp_api_ready.sh; \
		./scripts/wait_external_etcd_cluster.sh; \
		$(VAGRANT_RUN) up "cp$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
		$(VAGRANT_RUN) provision "cp$${i}"; \
		./scripts/wait_cp_api_ready.sh; \
		./scripts/wait_external_etcd_cluster.sh; \
	done

.PHONY: up-workers
up-workers:
	@if [ "$${KUBE_WORKER_COUNT:-0}" -le 0 ]; then echo "No workers configured (KUBE_WORKER_COUNT=0)."; exit 0; fi
	set -e; \
	for i in $$(seq 1 "$${KUBE_WORKER_COUNT}"); do \
		$(VAGRANT_RUN) up "worker$${i}" --provider "$${KUBE_PROVIDER}" --no-provision; \
		$(VAGRANT_RUN) provision "worker$${i}"; \
	done

.PHONY: up
up:
	@set +e; \
	$(MAKE) up-core; \
	status=$$?; \
	if [ $$status -ne 0 ] && [ "$(AUTO_CLEANUP_ON_FAILURE)" = "true" ]; then \
		echo "k8s bring-up failed; running automatic cleanup (make destroy)"; \
		$(MAKE) destroy || true; \
	fi; \
	exit $$status

.PHONY: up-core
up-core:
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Prepare fresh local artifact directory used by join/provision steps.
	mkdir -p .cluster
	rm -f .cluster/ready .cluster/failed
	# Start and provision API load balancer first when enabled.
	@effective_api_lb="false"; \
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ] && [ "$${KUBE_CP_COUNT:-1}" -gt 1 ]; then effective_api_lb="true"; fi; \
	echo "Topology: control-planes=$${KUBE_CP_COUNT} workers=$${KUBE_WORKER_COUNT} external-etcd=$${KUBE_ETCD_COUNT:-3} api-lb=$${effective_api_lb}"
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ] && [ "$${KUBE_CP_COUNT:-1}" -gt 1 ]; then $(VAGRANT_RUN) up api-lb --provider "$${KUBE_PROVIDER}" --no-provision; fi
	if [ "$${KUBE_API_LB_ENABLED:-true}" = "true" ] && [ "$${KUBE_CP_COUNT:-1}" -gt 1 ]; then $(VAGRANT_RUN) provision api-lb; fi
	# Bootstrap dedicated etcd nodes before cp1.
	$(MAKE) up-etcd
	# Bootstrap the first control plane (creates join artifacts).
	$(MAKE) up-cp1
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
	$(MAKE) up-cps
	# Bring up and provision workers deterministically.
	$(MAKE) up-workers
	# Ensure local kubeconfig points at the latest cp1 admin credentials.
	$(MAKE) kubeconfig

.PHONY: kubeconfig
kubeconfig:
	# Refresh local kubeconfig from cp1 for kubectl against this lab cluster.
	mkdir -p .cluster
	$(VAGRANT_RUN) ssh cp1 -c 'sudo cat /etc/kubernetes/admin.conf' > .cluster/admin.conf
	chmod 600 .cluster/admin.conf

.PHONY: kubeconfig-ha
kubeconfig-ha: kubeconfig
	# Build host kubeconfig that targets the API load balancer endpoint.
	./scripts/build_ha_kubeconfig.sh

.PHONY: validate
validate:
	./scripts/validate_cluster.sh

.PHONY: destroy
destroy:
	# Clear stale local lock files before actions.
	find .vagrant -type f -name '*.lock' -delete >/dev/null 2>&1 || true
	# Prune global Vagrant index and destroy any stale machine IDs for this workspace.
	./scripts/vagrant_global_cleanup.sh .
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
