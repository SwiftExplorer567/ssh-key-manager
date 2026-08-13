#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime
load_hosts
host_add "storage" "admin" "192.168.1.20" "2222" >/dev/null
load_hosts

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

finish_tests
