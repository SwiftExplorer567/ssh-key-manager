#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

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

config_attack_marker="$TEST_ROOT/config-must-not-execute"
printf '%s\n' 'BRAND="My Lab"' "touch $config_attack_marker" > "$SKM_SETTINGS_FILE"
load_settings
assert_eq "My Lab" "$APP_NAME" "allow-listed brand setting loads"
assert_false "configuration is parsed, never executed" test -e "$config_attack_marker"

finish_tests
