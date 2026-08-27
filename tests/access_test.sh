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
managed_original="$SKM_MANAGED_KEY"
ln -s "$managed_original" "$SKM_SSH_DIR/id_symlinked_skm"
ln -s "$managed_original.pub" "$SKM_SSH_DIR/id_symlinked_skm.pub"
SKM_MANAGED_KEY="$SKM_SSH_DIR/id_symlinked_skm"
MANAGED_KEY="$SKM_MANAGED_KEY"
assert_false "managed key symlinks are refused" ensure_managed_key >/dev/null 2>&1
SKM_MANAGED_KEY="$managed_original"
MANAGED_KEY="$managed_original"
rm -f "$SKM_SSH_DIR/id_symlinked_skm" "$SKM_SSH_DIR/id_symlinked_skm.pub"
assert_false "key generation rejects path traversal" key_generate "$SKM_SSH_DIR/../escaped-key" safe >/dev/null 2>&1
assert_false "key generation rejects nested key paths" key_generate "$SKM_SSH_DIR/nested/key" safe >/dev/null 2>&1
assert_false "key generation rejects unsafe control characters in comments" key_generate "$SKM_SSH_DIR/control-comment" $'bad\ecomment' >/dev/null 2>&1

fake_bin="$TEST_ROOT/fake-bin"
ssh_capture="$TEST_ROOT/ssh-args"
mkdir -p "$fake_bin"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$@" > "$SSH_CAPTURE"' \
    'if [ -n "${GRANT_CAPTURE:-}" ]; then cat > "$GRANT_CAPTURE"; printf added; exit 0; fi' \
    'case "$*" in' \
    '  *"for file in"*) printf "%s\n" "$REMOTE_INVENTORY_KEY";;' \
    '  *authorized_keys*) printf "%s\n" "$LOCAL_PUBLIC_KEY";;' \
    'esac' > "$fake_bin/ssh"
chmod 755 "$fake_bin/ssh"
export SSH_CAPTURE="$ssh_capture"
original_path="$PATH"
export PATH="$fake_bin:$PATH"
ssh_run_batch 0 true
assert_true "managed identity is used for passwordless checks" grep -Fxq "$SKM_MANAGED_KEY" "$ssh_capture"
assert_true "managed identity is the only identity offered for passwordless checks" grep -Fxq "IdentitiesOnly=yes" "$ssh_capture"
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
menu_item=$(authorized_key_menu_item "$second_key")
assert_true "revoke menu identifies a key by its comment" grep -Fq 'comment with spaces' <<< "$menu_item"
assert_true "revoke menu shows the key fingerprint" grep -Fq "$(key_fingerprint "$second_key")" <<< "$menu_item"
restricted_key="restrict $second_key"
assert_eq "$(key_fingerprint "$second_key")" "$(key_fingerprint "$restricted_key")" "restricted authorized keys remain visible in the revoke menu"
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

remote_inventory_private="$TEST_ROOT/remote_inventory"
ssh-keygen -q -t ed25519 -N '' -C 'rpi5-inventory-key' -f "$remote_inventory_private"
remote_inventory_key=$(read_public_key_file "$remote_inventory_private.pub")
grant_capture="$TEST_ROOT/granted-public-key"
export GRANT_CAPTURE="$grant_capture"
export PATH="$fake_bin:$PATH"
access_grant_public_key "storage" "$remote_inventory_key" >/dev/null
unset GRANT_CAPTURE
assert_eq "$remote_inventory_key" "$(cat "$grant_capture")" "a pasted client public key can be granted without moving a private key"

export REMOTE_INVENTORY_KEY="$remote_inventory_key"
export LOCAL_PUBLIC_KEY="$public_key"
inventory_output=$(key_list)
export PATH="$original_path"
assert_true "fleet inventory includes the connected server" grep -Fq 'storage · admin@192.168.1.20' <<< "$inventory_output"
assert_true "fleet inventory includes a remote public identity" grep -Fq 'rpi5-inventory-key' <<< "$inventory_output"
assert_true "fleet inventory separates public identities from allowed keys" grep -Fq 'Keys allowed to access this machine' <<< "$inventory_output"

finish_tests
