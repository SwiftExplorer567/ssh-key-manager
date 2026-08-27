.PHONY: build check-generated test lint ci

MODULE_SOURCES := $(wildcard src/*.sh) $(wildcard remote/*.sh)
BUILD_SOURCES := build/bundle.sh build/lint.sh
TEST_SOURCES := tests/test.sh tests/helpers/test_helper.sh $(wildcard tests/*_test.sh) $(wildcard tests/integration/*.sh)

build:
	./build/bundle.sh

check-generated:
	@tmp=$$(mktemp); trap 'rm -f "$$tmp" "$$tmp.sha256"' EXIT; ./build/bundle.sh "$$tmp"; cmp -s ssh-key-manager "$$tmp" && cmp -s ssh-key-manager.sha256 "$$tmp.sha256" || { echo "generated release files are stale; run make build" >&2; exit 1; }

test: build
	./tests/test.sh

lint: build
	bash -n ssh-key-manager install.sh uninstall.sh release.sh $(BUILD_SOURCES) $(MODULE_SOURCES) $(TEST_SOURCES)
	@if command -v shellcheck >/dev/null 2>&1; then ./build/lint.sh; else echo "shellcheck not installed; syntax checks completed"; fi

ci: check-generated test lint
