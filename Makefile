# Guestbook image catalog: build, test and (later) publish. The catalog is releases.yaml.
# Needs only Docker, bash, curl, make. Version arguments: make test VERSION=1.3.0 (default: all).

SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help list validate build test publish teardown test-publish lint

help: ## List the targets
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target> [VERSION=x.y.z]\n\nTargets:\n"} \
		/^[a-zA-Z_-]+:.*## / {printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

list: ## Show the catalog
	@scripts/catalog.sh list

validate: ## Check that releases.yaml follows the rules
	@scripts/catalog.sh validate

build: ## Build local images (never pushes, never tags latest): make build [VERSION=1.0.0]
	@scripts/build.sh $(VERSION)

test: ## Build, run and check the contract of every version (good pass, the broken one fails as designed)
	@scripts/test.sh $(VERSION)

publish: ## Push multi-arch images to GHCR: make publish VERSION=1.0.0|all (a dry run unless CONFIRM=yes)
	@scripts/publish.sh $(VERSION)

teardown: ## Delete published versions from GHCR: make teardown VERSION=1.0.0|all (a dry run unless CONFIRM=yes)
	@scripts/teardown.sh $(VERSION)

test-publish: ## Test publish and teardown against a local registry and a mock GitHub API (never touches GHCR)
	@tests/publish-teardown.sh

lint: ## bash -n on the scripts, plus shellcheck when installed
	@for f in scripts/*.sh tests/*.sh app/docker-entrypoint.d/*.sh; do bash -n "$$f" || exit 1; done
	@python3 -I -m py_compile scripts/ghcr-packages.py tests/mock-github-api.py && rm -rf scripts/__pycache__ tests/__pycache__
	@if command -v shellcheck >/dev/null; then shellcheck scripts/*.sh tests/*.sh app/docker-entrypoint.d/*.sh; else echo "shellcheck not installed: skipped"; fi
