SHELL := /bin/bash

TAG ?= 1.6.14.2
ROOT_DIR := $(abspath .)
BUILD_DIR := $(ROOT_DIR)/build-$(TAG)
LAUNCHER := $(ROOT_DIR)/gaffer-launcher

.PHONY: help build run smoke clean

help:
	@printf "gaffer-macos -- Gaffer with Cycles on macOS Apple Silicon\n\n"
	@printf "Targets:\n"
	@printf "  make build    Download, patch, and build Gaffer (takes ~30 min first time)\n"
	@printf "  make run      Launch Gaffer\n"
	@printf "  make smoke    Quick import test\n"
	@printf "  make clean    Remove everything (source + build)\n"
	@printf "\nVariables:\n"
	@printf "  TAG=%s  (Gaffer version)\n" "$(TAG)"

build:
	@TAG=$(TAG) bash "$(ROOT_DIR)/build.sh"

run:
	@[ -x "$(LAUNCHER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(LAUNCHER)"

smoke:
	@[ -x "$(LAUNCHER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(LAUNCHER)" env python -c 'import Gaffer, GafferCycles; print("OK:", Gaffer.About.versionString())'

clean:
	rm -rf "$(ROOT_DIR)/release-$(TAG)" "$(ROOT_DIR)/build-$(TAG)" "$(LAUNCHER)"
	@echo "Cleaned."
