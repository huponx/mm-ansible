SHELL := /bin/bash
PLAYBOOK ?= playbooks/site.yml
TAGS ?=
LIMIT ?=

# Load .env when present (ANSIBLE_HOST, ANSIBLE_USER, ANSIBLE_SSH_PORT)
LOAD_ENV = if [ -f .env ]; then set -a; . ./.env; set +a; fi
TAG_ARG = $(if $(TAGS),--tags $(TAGS),)
LIMIT_ARG = $(if $(LIMIT),--limit $(LIMIT),)

.PHONY: help deps lint syntax check deploy vault-edit vault-view vault-encrypt

help: ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

deps: ## Install Python and Galaxy dependencies
	pip install -r requirements.txt
	ansible-galaxy collection install -r requirements.yml

lint: ## yamllint + ansible-lint
	yamllint .
	ansible-lint

syntax: ## Syntax check (needs ANSIBLE_HOST to be set only for inventory parsing)
	@$(LOAD_ENV); ANSIBLE_HOST=$${ANSIBLE_HOST:-example.invalid} ansible-playbook $(PLAYBOOK) --syntax-check

check: ## Dry run with diff against the server, e.g. make check TAGS=redis
	@$(LOAD_ENV); ansible-playbook $(PLAYBOOK) --check --diff $(TAG_ARG) $(LIMIT_ARG)

deploy: ## Apply, e.g. make deploy TAGS=postgres_users
	@$(LOAD_ENV); ansible-playbook $(PLAYBOOK) --diff $(TAG_ARG) $(LIMIT_ARG)

vault-edit: ## Edit a vault file, e.g. make vault-edit F=postgres_vault.yml
	ansible-vault edit inventories/production/group_vars/all/$(F)

vault-view: ## View a vault file, e.g. make vault-view F=postgres_vault.yml
	ansible-vault view inventories/production/group_vars/all/$(F)

vault-encrypt: ## Encrypt a plaintext vault file, e.g. make vault-encrypt F=postgres_vault.yml
	ansible-vault encrypt inventories/production/group_vars/all/$(F)
