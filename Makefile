SHELL := /bin/bash

TAG ?= 1.7.6.0
ROOT_DIR := $(abspath .)
BUILD_DIR := $(ROOT_DIR)/build-$(TAG)
GAFFER := $(BUILD_DIR)/bin/gaffer

TARBALL := $(ROOT_DIR)/gaffer-$(TAG)-macos-arm64.tar.gz

.PHONY: build run smoke package clean

build:
	@TAG=$(TAG) bash "$(ROOT_DIR)/build.sh"

run:
	@[ -x "$(GAFFER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(GAFFER)"

smoke:
	@[ -x "$(GAFFER)" ] || { echo "Run 'make build' first."; exit 1; }
	@"$(GAFFER)" env python -c 'import Gaffer, GafferCycles; print("OK:", Gaffer.About.versionString())'

# Tarball for a GitHub release. Quarantine attributes are stripped by the
# build, but macOS re-applies them on download -- see the Gatekeeper note in
# the README for what users need to run after extracting.
package:
	@[ -x "$(GAFFER)" ] || { echo "Run 'make build' first."; exit 1; }
	@rm -f "$(TARBALL)"
	@tar czf "$(TARBALL)" -C "$(ROOT_DIR)" "build-$(TAG)"
	@echo "Wrote $(TARBALL)"

clean:
	rm -rf "$(ROOT_DIR)/release-$(TAG)" "$(ROOT_DIR)/build-$(TAG)"
	@echo "Cleaned."
