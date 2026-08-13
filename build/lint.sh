#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LINT_BUNDLE=$(mktemp "${TMPDIR:-/tmp}/skm-lint.XXXXXX")
trap 'rm -f "$LINT_BUNDLE"' EXIT HUP INT TERM

append_module() {
    sed '1{/^#!\/usr\/bin\/env bash$/d;}' "$1"
}

{
    printf '#!/usr/bin/env bash\n'
    append_module "$ROOT/src/runtime.sh"
    append_module "$ROOT/src/ui.sh"
    append_module "$ROOT/src/hosts.sh"
    append_module "$ROOT/src/ssh_transport.sh"
    printf '\nREMOTE_ADD_SCRIPT=""\n'
    printf 'REMOTE_REMOVE_SCRIPT=""\n'
    append_module "$ROOT/src/access.sh"
    append_module "$ROOT/src/updates.sh"
    append_module "$ROOT/src/cli.sh"
} > "$LINT_BUNDLE"

targets=(
    "$LINT_BUNDLE"
    "$ROOT/install.sh"
    "$ROOT/uninstall.sh"
    "$ROOT/release.sh"
    "$ROOT/build/bundle.sh"
    "$ROOT/build/lint.sh"
    "$ROOT/remote/authorized_add.sh"
    "$ROOT/remote/authorized_remove.sh"
    "$ROOT/tests/test.sh"
    "$ROOT/tests/helpers/test_helper.sh"
)

for path in "$ROOT"/tests/*_test.sh; do
    targets+=("$path")
done

shellcheck "${targets[@]}"
