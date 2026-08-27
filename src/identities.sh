# shellcheck shell=bash

# Identity metadata is local-only. It maps immutable SSH fingerprints to human
# names; SSH key comments remain untrusted display metadata.
declare -a IDENTITY_NAMES IDENTITY_FINGERPRINTS IDENTITY_TYPES IDENTITY_STATUSES

valid_fingerprint() { [[ "$1" =~ ^SHA256:[A-Za-z0-9+/=_-]+$ ]]; }
valid_identity_type() { [[ "$1" == "device" || "$1" == "server" || "$1" == "service" || "$1" == "other" ]]; }
valid_identity_status() { [[ "$1" == "active" || "$1" == "retired" ]]; }

load_identities() {
    IDENTITY_NAMES=() IDENTITY_FINGERPRINTS=() IDENTITY_TYPES=() IDENTITY_STATUSES=()
    local name fingerprint type status extra
    [[ -f "$IDENTITIES_FILE" ]] || return 0
    while IFS='|' read -r name fingerprint type status extra || [[ -n "$name" ]]; do
        name="$(trim "$name")"
        [[ -z "$name" || "$name" == \#* ]] && continue
        fingerprint="$(trim "$fingerprint")"
        type="$(trim "${type:-device}")"
        status="$(trim "${status:-active}")"
        if [[ -n "${extra:-}" ]] || ! valid_name "$name" || ! valid_fingerprint "$fingerprint" ||
           ! valid_identity_type "$type" || ! valid_identity_status "$status"; then
            warn "Skipped invalid identity record: $(sanitize_text "$name")"
            continue
        fi
        IDENTITY_NAMES+=("$name")
        IDENTITY_FINGERPRINTS+=("$fingerprint")
        IDENTITY_TYPES+=("$type")
        IDENTITY_STATUSES+=("$status")
    done < "$IDENTITIES_FILE"
}

save_identities() {
    local tmp i
    tmp=$(mktemp "$CONFIG_DIR/identities.conf.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    for i in "${!IDENTITY_NAMES[@]}"; do
        printf '%s|%s|%s|%s\n' \
            "${IDENTITY_NAMES[$i]}" "${IDENTITY_FINGERPRINTS[$i]}" \
            "${IDENTITY_TYPES[$i]}" "${IDENTITY_STATUSES[$i]}" >> "$tmp"
    done
    mv -f "$tmp" "$IDENTITIES_FILE"
}

identity_index() {
    local wanted="$1" i
    for i in "${!IDENTITY_NAMES[@]}"; do
        if [[ "${IDENTITY_NAMES[$i]}" == "$wanted" ]]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

identity_index_by_fingerprint() {
    local wanted="$1" i
    for i in "${!IDENTITY_FINGERPRINTS[@]}"; do
        if [[ "${IDENTITY_FINGERPRINTS[$i]}" == "$wanted" ]]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

identity_registry_configured() {
    load_identities
    (( ${#IDENTITY_NAMES[@]} > 0 ))
}

identity_name_for_fingerprint() {
    local index
    load_identities
    index=$(identity_index_by_fingerprint "$1") || return 1
    printf '%s' "${IDENTITY_NAMES[$index]}"
}

identity_status_for_fingerprint() {
    local index
    load_identities
    index=$(identity_index_by_fingerprint "$1") || return 1
    printf '%s' "${IDENTITY_STATUSES[$index]}"
}

identity_label_for_fingerprint() {
    local fingerprint="$1" fallback="${2:-unnamed key}" index label
    load_identities
    if index=$(identity_index_by_fingerprint "$fingerprint"); then
        label="${IDENTITY_NAMES[$index]}"
        [[ "${IDENTITY_STATUSES[$index]}" == "retired" ]] && label="$label [retired]"
        printf '%s' "$label"
    else
        sanitize_text "$fallback"
    fi
}

identity_list() {
    local i
    load_identities
    if (( ${#IDENTITY_NAMES[@]} == 0 )); then
        say "No identities registered. Add one with: skm identity add NAME SHA256:... [TYPE]"
        return 0
    fi
    printf '%-24s %-9s %-9s %s\n' NAME TYPE STATUS FINGERPRINT
    for i in "${!IDENTITY_NAMES[@]}"; do
        printf '%-24s %-9s %-9s %s\n' \
            "${IDENTITY_NAMES[$i]}" "${IDENTITY_TYPES[$i]}" \
            "${IDENTITY_STATUSES[$i]}" "${IDENTITY_FINGERPRINTS[$i]}"
    done
}

identity_add() {
    local name="$1" fingerprint="$2" type="${3:-device}"
    valid_name "$name" || { fail "Identity name must use letters, numbers, dot, dash, or underscore (max 63)."; return 1; }
    valid_fingerprint "$fingerprint" || { fail "Fingerprint must be an OpenSSH SHA256 fingerprint."; return 1; }
    valid_identity_type "$type" || { fail "Identity type must be device, server, service, or other."; return 1; }
    load_identities
    if identity_index "$name" >/dev/null 2>&1; then fail "Identity '$name' already exists."; return 1; fi
    if identity_index_by_fingerprint "$fingerprint" >/dev/null 2>&1; then fail "Fingerprint is already registered."; return 1; fi
    IDENTITY_NAMES+=("$name")
    IDENTITY_FINGERPRINTS+=("$fingerprint")
    IDENTITY_TYPES+=("$type")
    IDENTITY_STATUSES+=("active")
    save_identities || { fail "Could not save identity registry."; return 1; }
    ok "Registered $name ($type) as $fingerprint."
}

identity_show() {
    local name="$1" index
    load_identities
    index=$(identity_index "$name") || { fail "Unknown identity '$name'."; return 1; }
    printf 'Name:        %s\n' "${IDENTITY_NAMES[$index]}"
    printf 'Type:        %s\n' "${IDENTITY_TYPES[$index]}"
    printf 'Status:      %s\n' "${IDENTITY_STATUSES[$index]}"
    printf 'Fingerprint: %s\n' "${IDENTITY_FINGERPRINTS[$index]}"
}

identity_rename() {
    local name="$1" new_name="$2" index
    valid_name "$new_name" || { fail "Invalid identity name."; return 1; }
    load_identities
    index=$(identity_index "$name") || { fail "Unknown identity '$name'."; return 1; }
    if identity_index "$new_name" >/dev/null 2>&1; then fail "Identity '$new_name' already exists."; return 1; fi
    IDENTITY_NAMES[index]="$new_name"
    save_identities || { fail "Could not save identity registry."; return 1; }
    ok "Renamed $name to $new_name."
}

identity_set_status() {
    local name="$1" status="$2" index
    valid_identity_status "$status" || return 1
    load_identities
    index=$(identity_index "$name") || { fail "Unknown identity '$name'."; return 1; }
    IDENTITY_STATUSES[index]="$status"
    save_identities || { fail "Could not save identity registry."; return 1; }
    ok "Identity $name is now $status."
}

identity_retire() { identity_set_status "$1" retired; }
identity_activate() { identity_set_status "$1" active; }

fingerprint_is_authorized() {
    local wanted="$1" lines="$2" line fingerprint
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        fingerprint=$(key_fingerprint "$line" 2>/dev/null || true)
        [[ "$fingerprint" == "$wanted" ]] && return 0
    done <<< "$lines"
    return 1
}

access_matrix() {
    local i j local_label="this-machine" auth cell label
    local -a matrix_labels matrix_auth matrix_available
    load_identities
    (( ${#IDENTITY_NAMES[@]} > 0 )) || { fail "No identities registered. Run: skm identity add NAME SHA256:... [TYPE]"; return 1; }

    for i in "${!HOST_NAMES[@]}"; do
        if is_local_host "$i"; then local_label="${HOST_NAMES[$i]}"; break; fi
    done
    matrix_labels=("$local_label")
    if [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]]; then matrix_auth=("$(cat "$AUTHORIZED_KEYS")"); else matrix_auth=(""); fi
    matrix_available=("1")

    for i in "${!HOST_NAMES[@]}"; do
        is_local_host "$i" && continue
        matrix_labels+=("${HOST_NAMES[$i]}")
        if auth=$(remote_authorized_keys "$i" 2>/dev/null); then
            matrix_auth+=("$auth")
            matrix_available+=("1")
        else
            matrix_auth+=("")
            matrix_available+=("0")
        fi
    done

    say "Observed authorization matrix — yes means the fingerprint is present in authorized_keys."
    printf '%-24s %-9s %-9s' IDENTITY TYPE STATUS
    for label in "${matrix_labels[@]}"; do
        label=$(sanitize_text "$label")
        (( ${#label} > 14 )) && label="${label:0:13}…"
        printf ' %-14s' "$label"
    done
    printf '\n'

    for i in "${!IDENTITY_NAMES[@]}"; do
        printf '%-24s %-9s %-9s' "${IDENTITY_NAMES[$i]}" "${IDENTITY_TYPES[$i]}" "${IDENTITY_STATUSES[$i]}"
        for j in "${!matrix_labels[@]}"; do
            if [[ "${matrix_available[$j]}" != "1" ]]; then
                cell="?"
            elif fingerprint_is_authorized "${IDENTITY_FINGERPRINTS[$i]}" "${matrix_auth[$j]}"; then
                cell="yes"
            else
                cell="no"
            fi
            printf ' %-14s' "$cell"
        done
        printf '\n'
    done
}

AUDIT_ISSUES=0
declare -a AUDIT_FINDING_CODES AUDIT_FINDING_MESSAGES

audit_code_for_message() {
    case "$1" in
        *"invalid or unsupported authorized_keys entry"*) printf 'AUTHORIZED_ENTRY_INVALID' ;;
        *"control characters in comment"*) printf 'KEY_COMMENT_CONTROL_CHARS' ;;
        *"duplicate authorized fingerprint"*) printf 'AUTHORIZED_DUPLICATE' ;;
        *"retired identity"*"still authorized"*) printf 'RETIRED_AUTHORIZED' ;;
        *"unknown authorized fingerprint"*) printf 'AUTHORIZED_UNKNOWN' ;;
        *"public key path is a symlink"*) printf 'PUBLIC_KEY_SYMLINK' ;;
        *"duplicate public identity"*) printf 'PUBLIC_KEY_DUPLICATE' ;;
        *"broad 'Host *' block sets IdentityFile"*) printf 'SSH_CONFIG_BROAD_IDENTITY' ;;
        *"authorized_keys could not be read"*) printf 'AUDIT_INCOMPLETE' ;;
        *"policy: unknown fingerprint"*) printf 'POLICY_UNKNOWN_IDENTITY' ;;
        *"policy: unknown machine"*) printf 'POLICY_UNKNOWN_MACHINE' ;;
        *"policy: retired identity"*) printf 'POLICY_RETIRED_EXPECTATION' ;;
        *"MISSING expected identity"*) printf 'POLICY_MISSING' ;;
        *"EXCESS identity"*) printf 'POLICY_EXCESS' ;;
        *) printf 'TRUST_ISSUE' ;;
    esac
}

audit_issue() {
    local message="$*" code
    code=$(audit_code_for_message "$message")
    AUDIT_ISSUES=$((AUDIT_ISSUES + 1))
    AUDIT_FINDING_CODES+=("$code")
    AUDIT_FINDING_MESSAGES+=("$message")
    warn "$message"
}

audit_authorized_lines() {
    local label="$1" lines="$2" line fingerprint comment clean index seen=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        fingerprint=$(key_fingerprint "$line" 2>/dev/null || true)
        [[ -n "$fingerprint" ]] || { audit_issue "$label: invalid or unsupported authorized_keys entry."; continue; }
        comment=$(key_comment "$line")
        clean=$(sanitize_text "$comment")
        [[ "$comment" == "$clean" ]] || audit_issue "$label: control characters in comment for $fingerprint."
        if grep -Fqx "$fingerprint" <<< "$seen"; then
            audit_issue "$label: duplicate authorized fingerprint $fingerprint."
        else
            seen="${seen}${seen:+$'\n'}$fingerprint"
        fi
        if (( ${#IDENTITY_NAMES[@]} > 0 )); then
            if index=$(identity_index_by_fingerprint "$fingerprint"); then
                [[ "${IDENTITY_STATUSES[$index]}" == "retired" ]] && \
                    audit_issue "$label: retired identity '${IDENTITY_NAMES[$index]}' is still authorized."
            else
                audit_issue "$label: unknown authorized fingerprint $fingerprint (${clean:-unnamed key})."
            fi
        fi
    done <<< "$lines"
}

audit_local_key_files() {
    local file line fingerprint i prior=""
    local -a seen_fps seen_files
    seen_fps=() seen_files=()
    shopt -s nullglob
    for file in "$SSH_DIR"/*.pub; do
        if [[ -L "$file" ]]; then
            audit_issue "local: public key path is a symlink: $file"
            continue
        fi
        [[ -f "$file" ]] || continue
        line=$(read_public_key_file "$file" 2>/dev/null || true)
        [[ -n "$line" ]] || continue
        fingerprint=$(key_fingerprint "$line")
        prior=""
        for i in "${!seen_fps[@]}"; do
            if [[ "${seen_fps[$i]}" == "$fingerprint" ]]; then prior="${seen_files[$i]}"; break; fi
        done
        if [[ -n "$prior" ]]; then
            audit_issue "local: duplicate public identity $fingerprint in $prior and $file."
        else
            seen_fps+=("$fingerprint")
            seen_files+=("$file")
        fi
    done
    shopt -u nullglob
}

audit_ssh_config() {
    local config="$SSH_DIR/config"
    [[ -f "$config" ]] || return 0
    if awk '
        /^[[:space:]]*Host[[:space:]]+/ {
            broad=0
            for (i=2; i<=NF; i++) if ($i == "*") broad=1
            next
        }
        broad && /^[[:space:]]*IdentityFile[[:space:]]+/ { found=1 }
        END { exit !found }
    ' "$config"; then
        audit_issue "local: broad 'Host *' block sets IdentityFile; prefer explicit host identities."
    fi
}

audit() {
    local i auth label
    AUDIT_ISSUES=0
    AUDIT_FINDING_CODES=()
    AUDIT_FINDING_MESSAGES=()
    load_identities
    load_policy
    say "SSH trust audit"
    if (( ${#IDENTITY_NAMES[@]} == 0 )); then
        info "Identity registry is empty; unknown-key checks are skipped."
    else
        ok "Loaded ${#IDENTITY_NAMES[@]} registered identity/identities."
    fi
    if (( ${#POLICY_FINGERPRINTS[@]} == 0 )); then
        info "Desired-state policy is empty; policy drift checks are skipped."
    else
        ok "Loaded ${#POLICY_FINGERPRINTS[@]} desired access rule(s)."
        policy_audit_rules
    fi

    label="this machine"
    for i in "${!HOST_NAMES[@]}"; do
        if is_local_host "$i"; then label="${HOST_NAMES[$i]}"; break; fi
    done
    auth=""
    [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]] && auth=$(cat "$AUTHORIZED_KEYS")
    audit_authorized_lines "$label" "$auth"
    (( ${#POLICY_FINGERPRINTS[@]} == 0 )) || policy_audit_host "$label" "$auth"
    audit_local_key_files
    audit_ssh_config

    for i in "${!HOST_NAMES[@]}"; do
        is_local_host "$i" && continue
        if auth=$(remote_authorized_keys "$i" 2>/dev/null); then
            audit_authorized_lines "${HOST_NAMES[$i]}" "$auth"
            (( ${#POLICY_FINGERPRINTS[@]} == 0 )) || policy_audit_host "${HOST_NAMES[$i]}" "$auth"
        else
            audit_issue "${HOST_NAMES[$i]}: authorized_keys could not be read; audit is incomplete."
        fi
    done

    if (( AUDIT_ISSUES == 0 )); then
        ok "Audit found no trust issues."
        return 0
    fi
    warn "$AUDIT_ISSUES trust issue(s) found."
    return 1
}
