#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

duplicate_host_fails() { (host_add "storage" "admin" "host.example" "22" >/dev/null 2>&1); }
duplicate_local_fails() { (host_add "local-two" "admin" "localhost" "22" >/dev/null 2>&1); }
remove_policy_host_without_force_fails() { (host_remove "storage-renamed" >/dev/null 2>&1); }

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
host_add "local-one" "admin" "local" "22" >/dev/null
load_hosts
assert_eq "2" "${#HOST_NAMES[@]}" "saved machines reload"
assert_eq "storage" "${HOST_NAMES[0]}" "machine name is preserved"
assert_eq "2222" "${HOST_PORTS[0]}" "machine port is preserved"
assert_eq "600" "$(file_mode "$HOSTS_FILE")" "host configuration is private"
assert_false "duplicate machine names fail" duplicate_host_fails
assert_false "multiple aliases cannot represent the same local SKM node" duplicate_local_fails

host_edit "storage" "ops" "storage.example" "2200" >/dev/null
load_hosts
assert_eq "ops" "${HOST_USERS[0]}" "machine user can be edited"
assert_eq "storage.example" "${HOST_ADDRS[0]}" "machine address can be edited"
assert_eq "2200" "${HOST_PORTS[0]}" "machine port can be edited"

key_path=$(ensure_managed_key)
fingerprint=$(key_fingerprint "$(read_public_key_file "$key_path")")
identity_add "test-client" "$fingerprint" device >/dev/null
policy_expect "test-client" "storage" >/dev/null
host_rename "storage" "storage-renamed" >/dev/null
load_hosts
load_policy
assert_eq "storage-renamed" "${HOST_NAMES[0]}" "machine aliases can be renamed"
assert_eq "storage-renamed" "${POLICY_HOSTS[0]}" "machine rename migrates policy references"
assert_false "policy-referenced machines cannot be removed accidentally" remove_policy_host_without_force_fails
host_remove "storage-renamed" --force >/dev/null
load_hosts
load_policy
assert_eq "1" "${#HOST_NAMES[@]}" "forced machine removal removes the machine"
assert_eq "0" "${#POLICY_HOSTS[@]}" "forced machine removal also removes stale policy references"

# Runtime migration hardening: legacy settings files may predate the 0600 policy.
printf '%s\n' 'BRAND="Legacy Settings"' > "$SKM_SETTINGS_FILE"
chmod 644 "$SKM_SETTINGS_FILE"
ensure_runtime
assert_eq "600" "$(file_mode "$SKM_SETTINGS_FILE")" "runtime normalizes existing settings permissions"

# Never follow a settings symlink just to repair permissions.
settings_target="$TEST_ROOT/settings-target"
printf '%s\n' 'BRAND="Symlink Target"' > "$settings_target"
chmod 644 "$settings_target"
rm -f "$SKM_SETTINGS_FILE"
ln -s "$settings_target" "$SKM_SETTINGS_FILE"
ensure_runtime
assert_eq "644" "$(file_mode "$settings_target")" "runtime does not chmod settings symlink targets"
rm -f "$SKM_SETTINGS_FILE"

config_attack_marker="$TEST_ROOT/config-must-not-execute"
printf '%s\n' 'BRAND="My Lab"' "touch $config_attack_marker" > "$SKM_SETTINGS_FILE"
load_settings
assert_eq "My Lab" "$APP_NAME" "allow-listed brand setting loads"
assert_false "configuration is parsed, never executed" test -e "$config_attack_marker"

finish_tests
