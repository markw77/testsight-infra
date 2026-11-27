NAME := testsight-infra
# The lint target uses bash builtins (compgen); /bin/sh is dash on Debian/Ubuntu.
SHELL := /bin/bash
ANSIBLE_DIR := ansible
BOOTSTRAP_DIR := cluster-bootstrap
KUBECONFIG ?= $(HOME)/.kube/testsight-dedicated.yaml
VAULT_PASS = $(HOME)/.config/testsight/vault-pass
TOOLS_DIR ?= $(HOME)/.local/bin
export PATH := $(TOOLS_DIR):$(HOME)/.local/bin:$(PATH)
ANSIBLE_VENV ?= $(HOME)/.local/share/testsight/ansible-venv
ANSIBLE_BIN := $(ANSIBLE_VENV)/bin
PYTHON ?= python3

.PHONY: help install-tools lint-tools secrets-init site site-check kubeconfig bootstrap seal verify backup-now restore-test lint pre-commit

help:
	@echo "Targets: install-tools lint-tools secrets-init site site-check kubeconfig bootstrap seal verify backup-now restore-test lint"

install-tools:
	mkdir -p $(TOOLS_DIR)
	@command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required; install it with 'apt-get install -y python3'"; exit 1; }
	$(PYTHON) -m venv $(ANSIBLE_VENV) || { echo "error: python3 venv support is missing; install it with 'apt-get install -y python3-venv'"; exit 1; }
	$(ANSIBLE_BIN)/python -m pip install --quiet --upgrade pip
	$(ANSIBLE_BIN)/python -m pip install --quiet ansible-core==$$(. $(BOOTSTRAP_DIR)/versions.env && echo $$ANSIBLE_CORE_VERSION)
	ln -sfn $(ANSIBLE_BIN)/ansible $(ANSIBLE_BIN)/ansible-playbook $(ANSIBLE_BIN)/ansible-galaxy $(ANSIBLE_BIN)/ansible-vault $(TOOLS_DIR)/
	. $(BOOTSTRAP_DIR)/versions.env && \
	curl -fsSL -o $(TOOLS_DIR)/kubectl \
	  https://dl.k8s.io/release/$$KUBECTL_VERSION/bin/linux/amd64/kubectl && \
	  chmod +x $(TOOLS_DIR)/kubectl || rm -f $(TOOLS_DIR)/kubectl
	. $(BOOTSTRAP_DIR)/versions.env && \
	curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
	  | HELM_INSTALL_DIR=$(TOOLS_DIR) USE_SUDO=false bash -s -- --version v$${HELM_VERSION#v}
	. $(BOOTSTRAP_DIR)/versions.env && \
	curl -fsSL -o /tmp/kubeseal.tar.gz \
	  https://github.com/bitnami-labs/sealed-secrets/releases/download/$$KUBESEAL_VERSION/kubeseal-$${KUBESEAL_VERSION#v}-linux-amd64.tar.gz && \
	  tar -xzf /tmp/kubeseal.tar.gz -C $(TOOLS_DIR) kubeseal && rm -f /tmp/kubeseal.tar.gz
	. $(BOOTSTRAP_DIR)/versions.env && \
	curl -fsSL -o /tmp/kubeconform.tar.gz \
	  https://github.com/yannh/kubeconform/releases/download/$$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz && \
	  tar -xzf /tmp/kubeconform.tar.gz -C $(TOOLS_DIR) kubeconform && rm -f /tmp/kubeconform.tar.gz
	PATH=$(ANSIBLE_BIN):$$PATH ansible-galaxy collection install -r $(ANSIBLE_DIR)/requirements.yml

# Linters are installed as `uv tool`s rather than into the runtime venv. Two
# reasons: ansible-lint trusts tools under .../uv/tools and stays quiet, whereas
# a venv on PATH makes it warn that PATH was altered; and linting then needs
# neither the runtime venv nor ansible-playbook to be on PATH.
lint-tools:
	@command -v uv >/dev/null 2>&1 || { echo "error: uv is required; see https://docs.astral.sh/uv/"; exit 1; }
	uv tool install ansible-lint
	uv tool install yamllint
	uv tool install shellcheck-py
	@echo "kubeconform comes from install-tools"

secrets-init:
	@echo "Runs only when the vault does not exist yet; see docs/bring-up.md."
	bash $(BOOTSTRAP_DIR)/scripts/secrets-init.sh

site:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml

site-check:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/site.yml --syntax-check && \
	  ansible-playbook playbooks/site.yml --check --diff

kubeconfig:
	bash $(BOOTSTRAP_DIR)/scripts/fetch-kubeconfig.sh $(KUBECONFIG)

bootstrap:
	KUBECONFIG=$(KUBECONFIG) bash $(BOOTSTRAP_DIR)/scripts/bootstrap.sh

seal:
	KUBECONFIG=$(KUBECONFIG) ANSIBLE_VAULT_PASSWORD_FILE=$(VAULT_PASS) \
	  bash $(BOOTSTRAP_DIR)/scripts/seal-secrets.sh

verify:
	cd $(ANSIBLE_DIR) && ansible-playbook playbooks/verify.yml

backup-now:
	bash $(BOOTSTRAP_DIR)/scripts/backup-now.sh

restore-test:
	bash $(BOOTSTRAP_DIR)/scripts/restore-test.sh

# Mirrors .github/workflows/ci.yml. Each step prints only its own findings, so a
# clean run is silent; a trailing summary names what passed. The tool preflight
# runs first because this target used to end every line in `|| true`, reporting
# success while three of the four tools were not even installed.
lint:
	@for t in yamllint ansible-lint shellcheck kubeconform; do \
	  command -v $$t >/dev/null 2>&1 || { \
	    echo "error: missing lint tool: $$t (run 'make lint-tools', then 'make install-tools' for kubeconform)" >&2; \
	    exit 1; \
	  }; \
	done
	@echo "yamllint"
	@yamllint -c .yamllint $(ANSIBLE_DIR) $(BOOTSTRAP_DIR) .github
	@echo "ansible-lint"
	@cd $(ANSIBLE_DIR) && if [ -f group_vars/all/vault.yml ]; then \
	  VAULT_FILE="$$HOME/.config/testsight/vault-pass"; \
	  if [ -n "$$ANSIBLE_VAULT_PASSWORD_FILE" ] && [ -f "$$ANSIBLE_VAULT_PASSWORD_FILE" ]; then \
	    VAULT_FILE="$$ANSIBLE_VAULT_PASSWORD_FILE"; \
	  fi; \
	  if [ ! -f "$$VAULT_FILE" ]; then \
	    echo "error: vault password file not found: $$VAULT_FILE" >&2; \
	    echo "  set ANSIBLE_VAULT_PASSWORD_FILE or create ~/.config/testsight/vault-pass" >&2; \
	    exit 1; \
	  fi; \
	  ANSIBLE_VAULT_PASSWORD_FILE="$$VAULT_FILE" ansible-lint; \
	else \
	  unset ANSIBLE_VAULT_PASSWORD_FILE; \
	  ansible-lint; \
	fi
	@echo "shellcheck"
	@shellcheck $(BOOTSTRAP_DIR)/scripts/*.sh $(ANSIBLE_DIR)/roles/backup/files/*.sh
	@echo "kubeconform"
	@$(if $(wildcard $(BOOTSTRAP_DIR)/secrets/*.sealed.yaml), \
	  kubeconform -ignore-missing-schemas -strict $(BOOTSTRAP_DIR)/secrets, \
	  echo "  secrets: no sealed manifests (run 'make seal')")
	@kubeconform -ignore-missing-schemas -strict $(BOOTSTRAP_DIR)/argocd
	@echo "lint ok"

pre-commit:
	@command -v pre-commit >/dev/null 2>&1 || { \
	  echo "error: pre-commit not found; install with 'pip install pre-commit' or 'uv tool install pre-commit'" >&2; \
	  exit 1; \
	}
	@echo "pre-commit"
	pre-commit run --all-files
	@echo "pre-commit ok"