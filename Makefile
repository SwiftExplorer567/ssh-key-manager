.PHONY: test lint

test:
	./tests/test.sh

lint:
	bash -n ssh-key-manager install.sh uninstall.sh release.sh tests/test.sh
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck ssh-key-manager install.sh uninstall.sh release.sh tests/test.sh; else echo "shellcheck not installed; syntax checks completed"; fi
