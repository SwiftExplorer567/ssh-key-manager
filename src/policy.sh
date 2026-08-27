# shellcheck shell=bash

# Desired-state policy is local-only metadata. Each rule stores an immutable
# identity fingerprint and the saved machine name where that identity is
# expected to be authorized. An empty policy preserves the v1.2 observed-only
# behavior; once at least one rule exists, policy checks use closed-world
# semantics for registered active identities.
declare -a POLICY_FINGERPRINTS POLICY_HOSTS

load_policy() {
    POLICY_FINGERPRINTS=() POLICY_HOSTS=()
    local fingerprint host extra
    [[ -f "$POLICY_FILE" ]] || return 0
    while IFS='|' read -r fingerprint host extra || [[ -n "$fingerprint" ]]; do
        fingerprint="$(trim "$fingerprint")"
        [[ -z "$fingerprint" || "$fingerprint" == \#* ]] && continue
        host="$(trim "${host:-}")"
        if [[ -n "${extra:-}" ]] || ! valid_fingerprint "$fingerprint" || [[ -z "$host" || "$host" == *'|'* ]]; then
            warn "Skipped invalid policy record for $(sanitize_text "$fingerprint")"
            continue
        fi
        POLICY_FINGERPRINTS+=("$fingerprint")
        POLICY_HOSTS+=("$host")
    done < "$POLICY_FILE"
}

save_policy() {
    local tmp i
    tmp=$(mktemp "$CONFIG_DIR/policy.conf.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        printf '%s|%s\n' "${POLICY_FINGERPRINTS[$i]}" "${POLICY_HOSTS[$i]}" >> "$tmp"
    done
    mv -f "$tmp" "$POLICY_FILE"
}

policy_index() {
    local wanted_fp="$1" wanted_host="$2" i
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        if [[ "${POLICY_FINGERPRINTS[$i]}" == "$wanted_fp" && "${POLICY_HOSTS[$i]}" == "$wanted_host" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

policy_configured() {
    load_policy
    (( ${#POLICY_FINGERPRINTS[@]} > 0 ))
}

policy_expected() {
    local fingerprint="$1" host="$2"
    policy_index "$fingerprint" "$host" >/dev/null 2>&1
}

policy_expect() {
    local identity="$1" host="$2" identity_idx
    load_identities
    identity_idx=$(identity_index "$identity") || { fail "Unknown identity '$identity'."; return 1; }
    [[ "${IDENTITY_STATUSES[$identity_idx]}" == "active" ]] || {
        fail "Identity '$identity' is retired. Activate it before adding policy."
        return 1
    }
    require_host "$host" || return 1
    load_policy
    if policy_index "${IDENTITY_FINGERPRINTS[$identity_idx]}" "$host" >/dev/null 2>&1; then
        fail "Policy already expects $identity -> $host."
        return 1
    fi
    POLICY_FINGERPRINTS+=("${IDENTITY_FINGERPRINTS[$identity_idx]}")
    POLICY_HOSTS+=("$host")
    save_policy || { fail "Could not save desired-state policy."; return 1; }
    ok "Policy expects $identity -> $host."
}

policy_remove() {
    local identity="$1" host="$2" identity_idx index
    load_identities
    identity_idx=$(identity_index "$identity") || { fail "Unknown identity '$identity'."; return 1; }
    load_policy
    index=$(policy_index "${IDENTITY_FINGERPRINTS[$identity_idx]}" "$host") || {
        fail "No policy rule for $identity -> $host."
        return 1
    }
    unset 'POLICY_FINGERPRINTS[index]' 'POLICY_HOSTS[index]'
    POLICY_FINGERPRINTS=("${POLICY_FINGERPRINTS[@]}")
    POLICY_HOSTS=("${POLICY_HOSTS[@]}")
    save_policy || { fail "Could not save desired-state policy."; return 1; }
    ok "Removed policy expectation $identity -> $host."
}

policy_list() {
    local i identity_idx name type status
    load_identities
    load_policy
    if (( ${#POLICY_FINGERPRINTS[@]} == 0 )); then
        say "No desired-state policy configured. Add one with: skm policy expect IDENTITY MACHINE"
        return 0
    fi
    printf '%-24s %-9s %-9s %s\n' IDENTITY TYPE STATUS MACHINE
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        if identity_idx=$(identity_index_by_fingerprint "${POLICY_FINGERPRINTS[$i]}"); then
            name="${IDENTITY_NAMES[$identity_idx]}"
            type="${IDENTITY_TYPES[$identity_idx]}"
            status="${IDENTITY_STATUSES[$identity_idx]}"
        else
            name="unknown"
            type="-"
            status="-"
        fi
        printf '%-24s %-9s %-9s %s\n' "$name" "$type" "$status" "${POLICY_HOSTS[$i]}"
    done
}

policy_collect_snapshot() {
    local i auth local_label="this-machine"
    POLICY_MATRIX_LABELS=() POLICY_MATRIX_AUTHS=() POLICY_MATRIX_AVAILABLE=()
    for i in "${!HOST_NAMES[@]}"; do
        if is_local_host "$i"; then local_label="${HOST_NAMES[$i]}"; break; fi
    done
    POLICY_MATRIX_LABELS=("$local_label")
    if [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]]; then
        POLICY_MATRIX_AUTHS=("$(cat "$AUTHORIZED_KEYS")")
    else
        POLICY_MATRIX_AUTHS=("")
    fi
    POLICY_MATRIX_AVAILABLE=("1")

    for i in "${!HOST_NAMES[@]}"; do
        is_local_host "$i" && continue
        POLICY_MATRIX_LABELS+=("${HOST_NAMES[$i]}")
        if auth=$(remote_authorized_keys "$i" 2>/dev/null); then
            POLICY_MATRIX_AUTHS+=("$auth")
            POLICY_MATRIX_AVAILABLE+=("1")
        else
            POLICY_MATRIX_AUTHS+=("")
            POLICY_MATRIX_AVAILABLE+=("0")
        fi
    done
}

declare -a POLICY_MATRIX_LABELS POLICY_MATRIX_AUTHS POLICY_MATRIX_AVAILABLE

policy_cell() {
    local fingerprint="$1" host="$2" available="$3" auth="$4" expected=0 observed=0
    [[ "$available" == "1" ]] || { printf '?'; return; }
    policy_expected "$fingerprint" "$host" && expected=1
    fingerprint_is_authorized "$fingerprint" "$auth" && observed=1
    if (( expected == 1 && observed == 1 )); then
        printf 'OK'
    elif (( expected == 1 )); then
        printf 'MISSING'
    elif (( observed == 1 )); then
        printf 'EXCESS'
    else
        printf '-'
    fi
}

policy_matrix() {
    local i j label cell
    load_identities
    load_policy
    (( ${#IDENTITY_NAMES[@]} > 0 )) || { fail "No identities registered. Run: skm identity add NAME SHA256:... [TYPE]"; return 1; }
    (( ${#POLICY_FINGERPRINTS[@]} > 0 )) || { fail "No desired-state policy configured. Run: skm policy expect IDENTITY MACHINE"; return 1; }
    policy_collect_snapshot

    say "Desired-state matrix — OK matches policy; MISSING and EXCESS are drift."
    printf '%-24s %-9s %-9s' IDENTITY TYPE STATUS
    for label in "${POLICY_MATRIX_LABELS[@]}"; do
        label=$(sanitize_text "$label")
        (( ${#label} > 14 )) && label="${label:0:13}…"
        printf ' %-14s' "$label"
    done
    printf '\n'

    for i in "${!IDENTITY_NAMES[@]}"; do
        printf '%-24s %-9s %-9s' "${IDENTITY_NAMES[$i]}" "${IDENTITY_TYPES[$i]}" "${IDENTITY_STATUSES[$i]}"
        for j in "${!POLICY_MATRIX_LABELS[@]}"; do
            cell=$(policy_cell "${IDENTITY_FINGERPRINTS[$i]}" "${POLICY_MATRIX_LABELS[$j]}" \
                "${POLICY_MATRIX_AVAILABLE[$j]}" "${POLICY_MATRIX_AUTHS[$j]}")
            printf ' %-14s' "$cell"
        done
        printf '\n'
    done
}

POLICY_DRIFT=0

policy_drift_issue() {
    POLICY_DRIFT=$((POLICY_DRIFT + 1))
    warn "$*"
}

policy_validate_rules() {
    local i identity_idx
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        if ! identity_idx=$(identity_index_by_fingerprint "${POLICY_FINGERPRINTS[$i]}"); then
            policy_drift_issue "policy: unknown fingerprint ${POLICY_FINGERPRINTS[$i]}."
            continue
        fi
        if ! host_index "${POLICY_HOSTS[$i]}" >/dev/null 2>&1; then
            policy_drift_issue "policy: unknown machine '${POLICY_HOSTS[$i]}' for identity '${IDENTITY_NAMES[$identity_idx]}'."
        fi
        if [[ "${IDENTITY_STATUSES[$identity_idx]}" == "retired" ]]; then
            policy_drift_issue "policy: retired identity '${IDENTITY_NAMES[$identity_idx]}' is still expected on '${POLICY_HOSTS[$i]}'."
        fi
    done
}

policy_check() {
    local i j expected observed host
    POLICY_DRIFT=0
    load_identities
    load_policy
    (( ${#POLICY_FINGERPRINTS[@]} > 0 )) || { fail "No desired-state policy configured. Run: skm policy expect IDENTITY MACHINE"; return 1; }
    policy_validate_rules
    policy_collect_snapshot

    for j in "${!POLICY_MATRIX_LABELS[@]}"; do
        host="${POLICY_MATRIX_LABELS[$j]}"
        if [[ "${POLICY_MATRIX_AVAILABLE[$j]}" != "1" ]]; then
            policy_drift_issue "$host: desired-state check is incomplete because authorized_keys could not be read."
            continue
        fi
        for i in "${!IDENTITY_NAMES[@]}"; do
            [[ "${IDENTITY_STATUSES[$i]}" == "active" ]] || continue
            expected=0 observed=0
            policy_expected "${IDENTITY_FINGERPRINTS[$i]}" "$host" && expected=1
            fingerprint_is_authorized "${IDENTITY_FINGERPRINTS[$i]}" "${POLICY_MATRIX_AUTHS[$j]}" && observed=1
            if (( expected == 1 && observed == 0 )); then
                policy_drift_issue "MISSING ${IDENTITY_NAMES[$i]} -> $host"
            elif (( expected == 0 && observed == 1 )); then
                policy_drift_issue "EXCESS ${IDENTITY_NAMES[$i]} -> $host"
            fi
        done
    done

    if (( POLICY_DRIFT == 0 )); then
        ok "Desired-state policy matches observed authorization."
        return 0
    fi
    warn "$POLICY_DRIFT policy drift issue(s) found."
    return 1
}

policy_audit_rules() {
    local i identity_idx
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        if ! identity_idx=$(identity_index_by_fingerprint "${POLICY_FINGERPRINTS[$i]}"); then
            audit_issue "policy: unknown fingerprint ${POLICY_FINGERPRINTS[$i]}."
            continue
        fi
        if ! host_index "${POLICY_HOSTS[$i]}" >/dev/null 2>&1; then
            audit_issue "policy: unknown machine '${POLICY_HOSTS[$i]}' for identity '${IDENTITY_NAMES[$identity_idx]}'."
        fi
        if [[ "${IDENTITY_STATUSES[$identity_idx]}" == "retired" ]]; then
            audit_issue "policy: retired identity '${IDENTITY_NAMES[$identity_idx]}' is still expected on '${POLICY_HOSTS[$i]}'."
        fi
    done
}

policy_audit_host() {
    local host="$1" auth="$2" i expected observed
    for i in "${!IDENTITY_NAMES[@]}"; do
        [[ "${IDENTITY_STATUSES[$i]}" == "active" ]] || continue
        expected=0 observed=0
        policy_expected "${IDENTITY_FINGERPRINTS[$i]}" "$host" && expected=1
        fingerprint_is_authorized "${IDENTITY_FINGERPRINTS[$i]}" "$auth" && observed=1
        if (( expected == 1 && observed == 0 )); then
            audit_issue "$host: MISSING expected identity '${IDENTITY_NAMES[$i]}'."
        elif (( expected == 0 && observed == 1 )); then
            audit_issue "$host: EXCESS identity '${IDENTITY_NAMES[$i]}' is authorized but not expected."
        fi
    done
}
