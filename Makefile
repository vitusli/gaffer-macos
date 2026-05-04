SHELL := /bin/bash

TAG ?= 1.6.14.2
ROOT_DIR := $(abspath .)
BUILD_DIR := $(ROOT_DIR)/build-$(TAG)
GAFFER := $(BUILD_DIR)/bin/gaffer

.PHONY: build run smoke clean

build:
	@TAG=$(TAG) bash "$(ROOT_DIR)/build.sh"

run:
	@[ -x "$(GAFFER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(GAFFER)"

smoke:
	@[ -x "$(GAFFER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(GAFFER)" env python -c 'import Gaffer, GafferCycles; print("OK:", Gaffer.About.versionString())'

clean:
	rm -rf "$(ROOT_DIR)/release-$(TAG)" "$(ROOT_DIR)/build-$(TAG)"
	@echo "Cleaned."
