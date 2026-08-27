#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime
load_hosts
host_add "storage" "admin" "storage.example" "2222" >/dev/null
load_hosts

fake_bin="$TEST_ROOT/host-trust-bin"
mkdir -p "$fake_bin"
host_key="$TEST_ROOT/host_key"
other_key="$TEST_ROOT/other_host_key"
ssh-keygen -q -t ed25519 -N '' -f "$host_key"
ssh-keygen -q -t ed25519 -N '' -f "$other_key"
export HOST_SCAN_PUB="$host_key.pub"

cat > "$fake_bin/ssh-keyscan" <<'EOF'
#!/bin/sh
port=22
host=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) shift; port="$1" ;;
    -T) shift ;;
    *) host="$1" ;;
  esac
  shift
done
set -- $(cat "$HOST_SCAN_PUB")
printf '[%s]:%s %s %s\n' "$host" "$port" "$1" "$2"
EOF
cat > "$fake_bin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$SSH_CAPTURE"
exit 0
EOF
chmod 755 "$fake_bin/ssh-keyscan" "$fake_bin/ssh"
original_path="$PATH"
export PATH="$fake_bin:$PATH"

fingerprint=$(awk '{print $1, $2}' "$host_key.pub" | ssh-keygen -lf /dev/stdin | awk '{print $2}')
scan_output=$(host_fingerprint storage)
assert_true "host fingerprint command reports the scanned SHA256 fingerprint" grep -Fq "$fingerprint" <<< "$scan_output"
host_trust storage "$fingerprint" >/dev/null
assert_eq "600" "$(file_mode "$SKM_KNOWN_HOSTS_FILE")" "pinned host trust store is private"
assert_true "host trust stores the nonstandard-port known_hosts token" grep -Fq '[storage.example]:2222' "$SKM_KNOWN_HOSTS_FILE"
assert_true "host verify accepts the pinned key while it is still presented" host_verify storage

export HOST_SCAN_PUB="$other_key.pub"
assert_false "host verify detects a changed host key" host_verify storage >/dev/null 2>&1
export HOST_SCAN_PUB="$host_key.pub"

ssh_capture="$TEST_ROOT/pinned-ssh-args"
export SSH_CAPTURE="$ssh_capture"
ssh_run_batch 0 true
assert_true "pinned hosts force strict host-key checking" grep -Fxq 'StrictHostKeyChecking=yes' "$ssh_capture"
assert_true "pinned hosts use the SKM known_hosts file" grep -Fxq "UserKnownHostsFile=$SKM_KNOWN_HOSTS_FILE" "$ssh_capture"
assert_true "pinned hosts ignore global known_hosts fallback" grep -Fxq 'GlobalKnownHostsFile=/dev/null' "$ssh_capture"

host_untrust storage >/dev/null
assert_false "host untrust removes the saved pin" host_has_pin 0
export PATH="$original_path"

finish_tests
