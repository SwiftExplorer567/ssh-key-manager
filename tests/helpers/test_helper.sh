#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skm-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

export HOME="$TEST_ROOT/home"
export SKM_CONFIG_DIR="$HOME/config"
export SKM_HOSTS_FILE="$SKM_CONFIG_DIR/servers.conf"
export SKM_SETTINGS_FILE="$SKM_CONFIG_DIR/config"
export SKM_SSH_DIR="$HOME/.ssh"
export SKM_AUTHORIZED_KEYS="$SKM_SSH_DIR/authorized_keys"
export SKM_MANAGED_KEY="$SKM_SSH_DIR/id_ed25519_skm"
export SKM_TESTING=1
export NO_COLOR=1

# shellcheck disable=SC1090,SC1091
source "$ROOT/ssh-key-manager"

passes=0
failures=0

pass() { passes=$((passes + 1)); printf 'ok %d - %s\n' "$passes" "$1"; }
not_ok() { failures=$((failures + 1)); printf 'not ok - %s\n' "$1" >&2; }

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$label"; else not_ok "$label (expected '$expected', got '$actual')"; fi
}

assert_true() {
    local label="$1"; shift
    if "$@"; then pass "$label"; else not_ok "$label"; fi
}

assert_false() {
    local label="$1"; shift
    if "$@"; then not_ok "$label"; else pass "$label"; fi
}

file_mode() {
    if [[ "$(uname -s)" == "Darwin" ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

finish_tests() {
    if (( failures > 0 )); then
        printf '\n%d test(s) failed; %d passed.\n' "$failures" "$passes" >&2
        exit 1
    fi
    printf '\nAll %d tests passed.\n' "$passes"
}
