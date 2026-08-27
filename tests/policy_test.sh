#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091,SC2034
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime

HOST_NAMES=("localbox" "remotebox")
HOST_USERS=("tester" "tester")
HOST_ADDRS=("local" "192.0.2.10")
HOST_PORTS=("22" "22")

primary_private="$SKM_SSH_DIR/id_primary"
phone_private="$SKM_SSH_DIR/id_phone"
ssh-keygen -q -t ed25519 -N '' -C 'primary-old-comment' -f "$primary_private"
ssh-keygen -q -t ed25519 -N '' -C 'phone-old-comment' -f "$phone_private"

primary_key=$(read_public_key_file "$primary_private.pub")
phone_key=$(read_public_key_file "$phone_private.pub")
primary_fp=$(key_fingerprint "$primary_key")
phone_fp=$(key_fingerprint "$phone_key")

identity_add primary "$primary_fp" device >/dev/null
identity_add phone "$phone_fp" device >/dev/null

policy_expect primary localbox >/dev/null
policy_expect phone remotebox >/dev/null
assert_eq "600" "$(file_mode "$SKM_POLICY_FILE")" "policy file is private metadata"
assert_false "duplicate desired rule is rejected" policy_expect primary localbox
assert_true "policy list shows local expectation" grep -Fq 'primary' <<< "$(policy_list)"
assert_true "policy list shows remote expectation" grep -Fq 'remotebox' <<< "$(policy_list)"

identity_rename primary workstation >/dev/null
assert_true "identity rename keeps fingerprint-anchored policy" grep -Fq 'workstation' <<< "$(policy_list)"

printf '%s\n' "$primary_key" > "$SKM_AUTHORIZED_KEYS"
chmod 600 "$SKM_AUTHORIZED_KEYS"
REMOTE_AUTH="$phone_key"
remote_authorized_keys() {
    [[ "$1" == "1" ]] || return 1
    printf '%s\n' "$REMOTE_AUTH"
}

matrix_output=$(policy_matrix)
assert_true "policy matrix reports matching local authorization" grep -Eq 'workstation.*OK' <<< "$matrix_output"
assert_true "policy matrix reports matching remote authorization" grep -Eq 'phone.*OK' <<< "$matrix_output"
assert_false "matching matrix has no missing entries" grep -Fq 'MISSING' <<< "$matrix_output"
assert_false "matching matrix has no excess entries" grep -Fq 'EXCESS' <<< "$matrix_output"
assert_true "policy check succeeds when observed state matches" policy_check >/dev/null 2>&1

printf '%s\n%s\n' "$primary_key" "$phone_key" > "$SKM_AUTHORIZED_KEYS"
REMOTE_AUTH=""
set +e
drift_output=$(policy_check 2>&1)
drift_rc=$?
set -e
assert_eq "1" "$drift_rc" "policy check returns nonzero on drift"
assert_true "policy check flags excess authorization" grep -Fq 'EXCESS phone -> localbox' <<< "$drift_output"
assert_true "policy check flags missing authorization" grep -Fq 'MISSING phone -> remotebox' <<< "$drift_output"

set +e
audit_output=$(audit 2>&1)
audit_rc=$?
set -e
assert_eq "1" "$audit_rc" "trust audit includes policy drift"
assert_true "audit reports excess desired-state drift" grep -Fq "localbox: EXCESS identity 'phone'" <<< "$audit_output"
assert_true "audit reports missing desired-state drift" grep -Fq "remotebox: MISSING expected identity 'phone'" <<< "$audit_output"

identity_retire workstation >/dev/null
set +e
retired_output=$(policy_check 2>&1)
retired_rc=$?
set -e
assert_eq "1" "$retired_rc" "policy check rejects stale expectations for retired identities"
assert_true "retired policy expectation is identified" grep -Fq "retired identity 'workstation' is still expected" <<< "$retired_output"
identity_activate workstation >/dev/null

policy_remove phone remotebox >/dev/null
assert_false "removed expectation disappears from policy list" grep -Fq 'remotebox' <<< "$(policy_list)"

finish_tests
