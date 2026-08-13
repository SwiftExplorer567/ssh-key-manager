#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0
tests=(
    runtime_hosts_test.sh
    access_test.sh
    updates_install_test.sh
    ui_cli_test.sh
    uninstall_release_test.sh
)

for test_name in "${tests[@]}"; do
    printf '\n# %s\n' "$test_name"
    if ! bash "$ROOT/tests/$test_name"; then
        failures=$((failures + 1))
    fi
done

if (( failures > 0 )); then
    printf '\n%d test file(s) failed.\n' "$failures" >&2
    exit 1
fi

printf '\nAll test files passed.\n'
