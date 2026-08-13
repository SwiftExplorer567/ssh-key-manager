#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

# shellcheck disable=SC1091
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
duplicate_host_fails() { (host_add "storage" "admin" "host.example" "22" >/dev/null 2>&1); }

ensure_runtime
load_hosts

assert_true "machine names accept safe aliases" valid_name "server-b"
assert_false "machine names reject shell metacharacters" valid_name 'server;touch-pwned'
assert_true "IPv4 hosts are accepted" valid_host "192.168.1.20"
assert_false "option-like hosts are rejected" valid_host "-oProxyCommand=bad"
assert_true "valid ports are accepted" valid_port "2222"
assert_false "port zero is rejected" valid_port "0"
assert_false "ports over 65535 are rejected" valid_port "65536"

host_add "storage" "admin" "192.168.1.20" "2222" >/dev/null
load_hosts
assert_eq "1" "${#HOST_NAMES[@]}" "saved machine reloads"
assert_eq "storage" "${HOST_NAMES[0]}" "machine name is preserved"
assert_eq "2222" "${HOST_PORTS[0]}" "machine port is preserved"
assert_eq "600" "$(file_mode "$HOSTS_FILE")" "host configuration is private"
assert_false "duplicate machine names fail" duplicate_host_fails

key_path=$(ensure_managed_key)
assert_true "managed private key is created" test -f "$SKM_MANAGED_KEY"
assert_true "managed public key is created" test -f "$key_path"
assert_eq "600" "$(file_mode "$SKM_MANAGED_KEY")" "managed private key mode is 600"
assert_eq "644" "$(file_mode "$key_path")" "managed public key mode is 644"

fake_bin="$TEST_ROOT/fake-bin"
ssh_capture="$TEST_ROOT/ssh-args"
mkdir -p "$fake_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@" > "$SSH_CAPTURE"' > "$fake_bin/ssh"
chmod 755 "$fake_bin/ssh"
export SSH_CAPTURE="$ssh_capture"
original_path="$PATH"
export PATH="$fake_bin:$PATH"
ssh_run_batch 0 true
assert_true "managed identity is used for passwordless checks" grep -Fxq "$SKM_MANAGED_KEY" "$ssh_capture"
export PATH="$original_path"

public_key=$(read_public_key_file "$key_path")
assert_true "generated public key validates" valid_public_key "$public_key"
# shellcheck disable=SC2016
assert_false "command text is not a public key" valid_public_key '$(touch /tmp/pwned)'
assert_eq "added" "$(authorized_add_local "$public_key")" "first local grant is added"
assert_eq "exists" "$(authorized_add_local "$public_key")" "duplicate local grant is idempotent"
assert_eq "1" "$(grep -c "$(key_blob "$public_key")" "$SKM_AUTHORIZED_KEYS")" "duplicate grant creates one line"
assert_eq "600" "$(file_mode "$SKM_AUTHORIZED_KEYS")" "authorized_keys mode is 600"

second_private="$SKM_SSH_DIR/id_test_second"
# shellcheck disable=SC2016
ssh-keygen -q -t ed25519 -N '' -C 'comment with spaces; $(touch should-not-run)' -f "$second_private"
second_key=$(read_public_key_file "$second_private.pub")
assert_eq "added" "$(authorized_add_local "$second_key")" "second local grant is added"
authorized_remove_local "$(key_blob "$second_key")"
assert_false "selected public key can be revoked" grep -q "$(key_blob "$second_key")" "$SKM_AUTHORIZED_KEYS"
assert_true "authorized_keys mutation creates a backup" test -f "$SKM_AUTHORIZED_KEYS.skm.bak"

remote_home="$TEST_ROOT/remote"
mkdir -p "$remote_home"
attack_marker="$TEST_ROOT/remote-command-ran"
malicious_comment_key="$(awk '{print $1, $2}' <<< "$second_key") \$(touch $attack_marker)"
remote_result=$(printf '%s\n' "$malicious_comment_key" | HOME="$remote_home" sh -c "$REMOTE_ADD_SCRIPT")
assert_eq "added" "$remote_result" "remote grant script accepts a valid public key"
assert_false "public-key comments are never executed remotely" test -e "$attack_marker"
assert_eq "exists" "$(printf '%s\n' "$malicious_comment_key" | HOME="$remote_home" sh -c "$REMOTE_ADD_SCRIPT")" "remote grant is idempotent"
printf '%s\n' "$(key_blob "$malicious_comment_key")" | HOME="$remote_home" sh -c "$REMOTE_REMOVE_SCRIPT"
assert_false "remote revoke removes only the selected key" grep -q "$(key_blob "$malicious_comment_key")" "$remote_home/.ssh/authorized_keys"
assert_true "remote revoke creates a backup" test -f "$remote_home/.ssh/authorized_keys.skm.bak"

printf '%s\n' 'BRAND="My Lab"' 'touch /tmp/skm-config-must-not-execute' > "$SKM_SETTINGS_FILE"
load_settings
assert_eq "My Lab" "$APP_NAME" "allow-listed brand setting loads"
assert_false "configuration is parsed, never executed" test -e /tmp/skm-config-must-not-execute

# shellcheck disable=SC2034
SKM_TEST_LATEST_VERSION="99.0.0"
check_for_updates true
assert_eq "99.0.0" "$LATEST_VERSION" "release update checks parse a newer version"
assert_eq "1" "$UPDATE_AVAILABLE" "newer releases set the update badge"
assert_true "semantic version comparison accepts newer minor versions" version_is_newer "1.1.0" "1.0.9"
assert_false "semantic version comparison rejects older versions" version_is_newer "0.9.9" "1.0.0"
unset SKM_TEST_LATEST_VERSION

# These globals are consumed by sourced TUI functions.
# shellcheck disable=SC2034
HOST_NAMES=("Mac Mini" "rpi5")
# shellcheck disable=SC2034
HOST_USERS=("homelab" "root")
# shellcheck disable=SC2034
HOST_ADDRS=("local" "192.168.31.179")
HOST_PORTS=("22" "22")
# shellcheck disable=SC2034
HOST_STATUSES=("local" "ready")
SKM_FORCE_TUI=1 select_host "Test which machine?" false <<< "2" >/dev/null
assert_eq "rpi5" "$SELECTED_HOST" "TUI host selection returns only the selected name"
assert_eq "1" "$SELECTED_HOST_INDEX" "TUI host selection preserves the selected index"
assert_false "unknown hosts stop instead of falling back to index zero" require_host "missing-host"
assert_eq "-1" "$RESOLVED_HOST_INDEX" "failed host lookup clears the resolved index"
SKM_FORCE_TUI=1 select_host "Remote only" true <<< "1" >/dev/null
assert_eq "rpi5" "$SELECTED_HOST" "remote actions exclude the local machine"
SKM_FORCE_TUI=1 run_menu "Arrow test" "" "One|First" "Two|Second" "Three|Third" <<< $'\e[B\e[B\n' >/dev/null
assert_eq "2" "$MENU_RESULT" "arrow-key navigation selects the highlighted item"

install_fake_bin="$TEST_ROOT/install-fake-bin"
install_prefix="$TEST_ROOT/installed/bin"
mkdir -p "$install_fake_bin"
cat > "$install_fake_bin/curl" <<'EOF'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then shift; output="$1"; fi
  shift
done
cp "${UPDATE_SOURCE:-$INSTALL_SOURCE}" "$output"
EOF
chmod 755 "$install_fake_bin/curl"
INSTALL_SOURCE="$ROOT/ssh-key-manager" PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/installer-home" \
    bash -u -s -- --prefix "$install_prefix" < "$ROOT/install.sh" >/dev/null
assert_eq "1.0.0" "$(HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 "$install_prefix/skm" version)" "piped installer works with nounset enabled"

update_source="$TEST_ROOT/ssh-key-manager-1.1.0"
sed 's/^VERSION="1.0.0"/VERSION="1.1.0"/' "$ROOT/ssh-key-manager" > "$update_source"
chmod 755 "$update_source"
INSTALL_SOURCE="$ROOT/ssh-key-manager" UPDATE_SOURCE="$update_source" SKM_TEST_LATEST_VERSION="1.1.0" \
    PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 \
    "$install_prefix/skm" update install >/dev/null
assert_eq "1.1.0" "$(HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 "$install_prefix/skm" version)" "self-update atomically installs a validated release"
assert_true "self-update keeps a rollback copy" test -f "$install_prefix/ssh-key-manager.previous"

assert_eq "1.0.0" "$(HOME="$HOME" SKM_TESTING=0 NO_COLOR=1 bash "$ROOT/ssh-key-manager" version)" "version command works"
assert_true "help explains the access direction" bash -c "HOME='$HOME' SKM_TESTING=0 NO_COLOR=1 bash '$ROOT/ssh-key-manager' help | grep -q 'This machine -> SERVER'"
assert_true "ambiguous legacy wording is rejected" bash -c "HOME='$HOME' SKM_TESTING=0 NO_COLOR=1 bash '$ROOT/ssh-key-manager' give-access 2>&1 | grep -q 'ambiguous'"

if (( failures > 0 )); then
    printf '\n%d test(s) failed; %d passed.\n' "$failures" "$passes" >&2
    exit 1
fi
printf '\nAll %d tests passed.\n' "$passes"
