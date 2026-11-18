SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-builtin-rules --warn-undefined-variables

ARCH ?=

DOWNLOAD := ./images/download.sh
ARCH_FLAG := $(if $(ARCH),--arch $(ARCH))
SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*')

.PHONY: help image image-verify lint fmt clean

help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z_-]+:.*## / { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\nVariables:\n  ARCH=amd64|arm64  Target architecture (default: host)\n'

image: ## Download and verify the Debian image
	@$(DOWNLOAD) $(ARCH_FLAG)

image-verify: ## Verify the local Debian image without downloading it
	@$(DOWNLOAD) $(ARCH_FLAG) --verify-only

lint: ## Run shellcheck and check formatting with shfmt
	shellcheck $(SCRIPTS)
	shfmt -d $(SCRIPTS)

fmt: ## Format shell scripts with shfmt
	shfmt -w $(SCRIPTS)

clean: ## Remove downloaded images and partial downloads
	rm -f images/downloads/*.iso images/downloads/*.part
