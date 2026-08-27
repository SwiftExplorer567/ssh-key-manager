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
ssh-keygen -q -t ed25519 -N '' -C 'primary' -f "$primary_private"
ssh-keygen -q -t ed25519 -N '' -C 'phone' -f "$phone_private"
primary_key=$(read_public_key_file "$primary_private.pub")
phone_key=$(read_public_key_file "$phone_private.pub")
primary_fp=$(key_fingerprint "$primary_key")
phone_fp=$(key_fingerprint "$phone_key")

identity_add primary "$primary_fp" device >/dev/null
identity_add phone "$phone_fp" device >/dev/null
policy_expect primary localbox >/dev/null
policy_expect phone remotebox >/dev/null

export_path="$TEST_ROOT/trust-config.skm"
config_export "$export_path" >/dev/null
assert_eq "600" "$(file_mode "$export_path")" "exported trust configuration is private"
assert_true "export has a versioned header" grep -Fqx 'SKM-TRUST-CONFIG|1' "$export_path"
assert_true "export contains identity records" grep -Fq "IDENTITY|primary|$primary_fp|device|active" "$export_path"
assert_true "export contains policy records" grep -Fq "POLICY|$phone_fp|remotebox" "$export_path"
assert_true "exported config validates" config_validate "$export_path" >/dev/null

identity_rename primary changed >/dev/null
policy_remove phone remotebox >/dev/null
config_import "$export_path" >/dev/null
assert_true "import restores canonical identity names" grep -Fq 'primary' <<< "$(identity_list)"
assert_false "import replaces changed identity metadata" grep -Fq 'changed' <<< "$(identity_list)"
assert_true "import restores desired-state policy" grep -Fq 'remotebox' <<< "$(policy_list)"
backup_exists() { compgen -G "$1" >/dev/null; }
assert_true "import creates identity backup" backup_exists "$SKM_IDENTITIES_FILE.pre-import-*"
assert_true "import creates policy backup" backup_exists "$SKM_POLICY_FILE.pre-import-*"

invalid_path="$TEST_ROOT/invalid-trust-config.skm"
sed 's/|remotebox$/|missingbox/' "$export_path" > "$invalid_path"
before_ids=$(cat "$SKM_IDENTITIES_FILE")
before_policy=$(cat "$SKM_POLICY_FILE")
assert_false "import validation rejects unknown machine aliases" config_validate "$invalid_path"
assert_eq "$before_ids" "$(cat "$SKM_IDENTITIES_FILE")" "failed validation leaves identities unchanged"
assert_eq "$before_policy" "$(cat "$SKM_POLICY_FILE")" "failed validation leaves policy unchanged"

printf '%s\n' "$primary_key" > "$SKM_AUTHORIZED_KEYS"
chmod 600 "$SKM_AUTHORIZED_KEYS"
REMOTE_AUTH="$phone_key"
remote_authorized_keys() {
    [[ "$1" == "1" ]] || return 1
    printf '%s\n' "$REMOTE_AUTH"
}

json_ok=$(policy_check_json)
assert_true "policy JSON reports success" grep -Fq '"ok":true' <<< "$json_ok"
assert_true "policy JSON reports zero issues" grep -Fq '"issue_count":0' <<< "$json_ok"
assert_false "policy JSON contains no terminal escapes" grep -q $'\033' <<< "$json_ok"

audit_ok=$(audit_json)
assert_true "audit JSON reports success" grep -Fq '"ok":true' <<< "$audit_ok"

printf '%s\n%s\n' "$primary_key" "$phone_key" > "$SKM_AUTHORIZED_KEYS"
REMOTE_AUTH=""
set +e
json_drift=$(policy_check_json)
json_drift_rc=$?
set -e
assert_eq "1" "$json_drift_rc" "policy JSON preserves nonzero drift exit status"
assert_true "policy JSON contains missing drift" grep -Fq 'MISSING phone -> remotebox' <<< "$json_drift"
assert_true "policy JSON contains excess drift" grep -Fq 'EXCESS phone -> localbox' <<< "$json_drift"
assert_true "policy JSON exposes issue count" grep -Fq '"issue_count":2' <<< "$json_drift"
assert_true "policy JSON exposes structured findings" grep -Fq '"findings":[' <<< "$json_drift"
assert_true "policy JSON uses a stable missing-policy code" grep -Fq '"code":"POLICY_MISSING"' <<< "$json_drift"
assert_true "policy JSON uses a stable excess-policy code" grep -Fq '"code":"POLICY_EXCESS"' <<< "$json_drift"

set +e
audit_drift=$(audit_json)
audit_drift_rc=$?
set -e
assert_eq "1" "$audit_drift_rc" "audit JSON preserves nonzero trust exit status"
assert_true "audit JSON contains desired-state drift" grep -Fq "EXCESS identity 'phone'" <<< "$audit_drift"
assert_true "audit JSON emits stable structured policy codes" grep -Fq '"code":"POLICY_EXCESS"' <<< "$audit_drift"

# Identity sync plans changes against the remote registry and refuses to orphan
# remote policy. It intentionally never mirrors policy aliases.
remote_home="$TEST_ROOT/remote-home"
mkdir -p "$remote_home/.config/ssh-key-manager"
ssh_run_batch() {
    local index="$1"; shift
    local script="$1"
    [[ "$index" == "1" ]] || return 1
    (
        unset SKM_CONFIG_DIR XDG_CONFIG_HOME
        export HOME="$remote_home"
        sh -c "$script"
    )
}

sync_dry_run=$(sync_identities remotebox --dry-run)
assert_true "identity sync dry-run reports additions" grep -Fq 'ADD' <<< "$sync_dry_run"
assert_false "identity sync dry-run does not create a remote registry" test -e "$remote_home/.config/ssh-key-manager/identities.conf"

sync_output=$(sync_identities remotebox)
remote_registry="$remote_home/.config/ssh-key-manager/identities.conf"
assert_true "identity sync reports success" grep -Fq 'Synced 2 identities' <<< "$sync_output"
assert_true "identity sync creates remote registry" test -f "$remote_registry"
assert_eq "600" "$(file_mode "$remote_registry")" "synced remote registry is private"
assert_true "identity sync preserves canonical fingerprint mapping" grep -Fq "primary|$primary_fp|device|active" "$remote_registry"
assert_false "identity sync does not create a remote policy" test -e "$remote_home/.config/ssh-key-manager/policy.conf"

printf '%s|remote-only-host\n' "$phone_fp" > "$remote_home/.config/ssh-key-manager/policy.conf"
identity_retire phone >/dev/null
before_remote_registry=$(cat "$remote_registry")
assert_false "identity sync dry-run reports remote policy impact" sync_identities remotebox --dry-run >/dev/null 2>&1
assert_false "identity sync refuses registry changes that would orphan remote policy" sync_identities remotebox >/dev/null 2>&1
assert_eq "$before_remote_registry" "$(cat "$remote_registry")" "refused sync leaves the remote registry unchanged"
identity_activate phone >/dev/null

finish_tests
