#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091,SC2034
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime
load_hosts

# Keep the trust-matrix test local and deterministic.
HOST_NAMES=("localbox")
HOST_USERS=("tester")
HOST_ADDRS=("local")
HOST_PORTS=("22")

active_private="$SKM_SSH_DIR/id_active"
retired_private="$SKM_SSH_DIR/id_retired"
unknown_private="$SKM_SSH_DIR/id_unknown"
ssh-keygen -q -t ed25519 -N '' -C 'legacy-active-comment' -f "$active_private"
ssh-keygen -q -t ed25519 -N '' -C 'legacy-retired-comment' -f "$retired_private"
ssh-keygen -q -t ed25519 -N '' -C 'unknown-comment' -f "$unknown_private"

active_key=$(read_public_key_file "$active_private.pub")
retired_key=$(read_public_key_file "$retired_private.pub")
unknown_key=$(read_public_key_file "$unknown_private.pub")
active_fp=$(key_fingerprint "$active_key")
retired_fp=$(key_fingerprint "$retired_key")

identity_add "windows-main" "$active_fp" device >/dev/null
identity_add "old-device" "$retired_fp" device >/dev/null
assert_eq "600" "$(file_mode "$SKM_IDENTITIES_FILE")" "identity registry is private metadata"
assert_false "duplicate fingerprints cannot be registered twice" identity_add "duplicate-device" "$active_fp" device
assert_true "identity list shows canonical name" grep -Fq 'windows-main' <<< "$(identity_list)"
assert_true "identity show includes fingerprint" grep -Fq "$active_fp" <<< "$(identity_show windows-main)"

identity_rename windows-main desktop-main >/dev/null
assert_eq "desktop-main" "$(identity_name_for_fingerprint "$active_fp")" "identity rename preserves fingerprint mapping"
identity_retire old-device >/dev/null
assert_eq "retired" "$(identity_status_for_fingerprint "$retired_fp")" "identity can be retired"

printf '%s\n%s\n' "$active_key" "$retired_key" > "$SKM_AUTHORIZED_KEYS"
unknown_base="$(key_algorithm "$unknown_key") $(key_blob "$unknown_key")"
printf '%s bad\033[Acomment\n' "$unknown_base" >> "$SKM_AUTHORIZED_KEYS"
chmod 600 "$SKM_AUTHORIZED_KEYS"

# Simulate the duplicate/symlink key clutter found during a real cleanup.
cp "$active_private.pub" "$SKM_SSH_DIR/id_active_duplicate.pub"
ln -s "$active_private.pub" "$SKM_SSH_DIR/id_active_alias.pub"
printf 'Host *\n  IdentityFile ~/.ssh/id_ed25519_skm\n' > "$SKM_SSH_DIR/config"
chmod 600 "$SKM_SSH_DIR/config"

inventory_output=$(key_list)
assert_true "inventory prefers registry identity names over legacy comments" grep -Fq 'desktop-main' <<< "$inventory_output"
assert_false "inventory never emits terminal escape characters from comments" grep -q $'\033' <<< "$inventory_output"

matrix_output=$(access_matrix)
assert_true "matrix names registered identities" grep -Fq 'desktop-main' <<< "$matrix_output"
assert_true "matrix shows observed authorization" grep -Eq 'desktop-main.*yes' <<< "$matrix_output"
assert_true "matrix marks retired identities" grep -Eq 'old-device.*retired.*yes' <<< "$matrix_output"

set +e
audit_output=$(audit 2>&1)
audit_rc=$?
set -e
assert_eq "1" "$audit_rc" "audit returns nonzero when trust issues are found"
assert_true "audit flags retired authorized identities" grep -Fq "retired identity 'old-device'" <<< "$audit_output"
assert_true "audit flags unknown authorized fingerprints" grep -Fq 'unknown authorized fingerprint' <<< "$audit_output"
assert_true "audit flags terminal control characters" grep -Fq 'control characters in comment' <<< "$audit_output"
assert_true "audit flags duplicate local public identities" grep -Fq 'duplicate public identity' <<< "$audit_output"
assert_true "audit flags public-key symlinks" grep -Fq 'public key path is a symlink' <<< "$audit_output"
assert_true "audit flags broad Host-star IdentityFile rules" grep -Fq "broad 'Host *' block sets IdentityFile" <<< "$audit_output"

identity_activate old-device >/dev/null
assert_eq "active" "$(identity_status_for_fingerprint "$retired_fp")" "retired identity can be reactivated"

finish_tests
