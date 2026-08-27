# shellcheck shell=bash

# Fleet automation deliberately separates identity synchronization from policy.
# Identity registries are fingerprint-anchored and portable. Policy rules refer
# to local SKM machine aliases, so they are exported/imported with validation but
# are never blindly mirrored by `skm sync identities`.

declare -a IMPORT_ID_NAMES IMPORT_ID_FINGERPRINTS IMPORT_ID_TYPES IMPORT_ID_STATUSES
declare -a IMPORT_POLICY_FINGERPRINTS IMPORT_POLICY_HOSTS
declare -a SYNC_REMOTE_ID_NAMES SYNC_REMOTE_ID_FINGERPRINTS SYNC_REMOTE_ID_TYPES SYNC_REMOTE_ID_STATUSES
declare -a SYNC_REMOTE_POLICY_FINGERPRINTS SYNC_REMOTE_POLICY_HOSTS

config_write_snapshot() {
    local i
    load_identities
    load_policy
    printf 'SKM-TRUST-CONFIG|1\n'
    for i in "${!IDENTITY_NAMES[@]}"; do
        printf 'IDENTITY|%s|%s|%s|%s\n' \
            "${IDENTITY_NAMES[$i]}" "${IDENTITY_FINGERPRINTS[$i]}" \
            "${IDENTITY_TYPES[$i]}" "${IDENTITY_STATUSES[$i]}"
    done
    for i in "${!POLICY_FINGERPRINTS[@]}"; do
        printf 'POLICY|%s|%s\n' "${POLICY_FINGERPRINTS[$i]}" "${POLICY_HOSTS[$i]}"
    done
}

config_export() {
    local destination="${1:--}" tmp parent
    if [[ "$destination" == "-" ]]; then
        config_write_snapshot
        return 0
    fi
    parent=$(dirname "$destination")
    [[ -d "$parent" ]] || { fail "Export directory does not exist: $parent"; return 1; }
    tmp=$(mktemp "$parent/.skm-export.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if ! config_write_snapshot > "$tmp"; then
        rm -f "$tmp"
        fail "Could not export trust configuration."
        return 1
    fi
    mv -f "$tmp" "$destination"
    chmod 600 "$destination" 2>/dev/null || true
    ok "Exported trust configuration to $destination."
}

import_identity_index_by_fingerprint() {
    local wanted="$1" i
    for i in "${!IMPORT_ID_FINGERPRINTS[@]}"; do
        [[ "${IMPORT_ID_FINGERPRINTS[$i]}" == "$wanted" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

config_parse_file() {
    local path="$1" line line_no=0 kind a b c d extra i identity_idx
    IMPORT_ID_NAMES=() IMPORT_ID_FINGERPRINTS=() IMPORT_ID_TYPES=() IMPORT_ID_STATUSES=()
    IMPORT_POLICY_FINGERPRINTS=() IMPORT_POLICY_HOSTS=()
    [[ -f "$path" ]] || { fail "Config file not found: $path"; return 1; }

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        line="${line%$'\r'}"
        if (( line_no == 1 )); then
            [[ "$line" == "SKM-TRUST-CONFIG|1" ]] || { fail "Unsupported or invalid trust config header."; return 1; }
            continue
        fi
        [[ -z "$line" ]] && continue
        IFS='|' read -r kind a b c d extra <<< "$line"
        case "$kind" in
            IDENTITY)
                [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || {
                    fail "Invalid identity record on line $line_no."; return 1;
                }
                valid_name "$a" || { fail "Invalid identity name on line $line_no."; return 1; }
                valid_fingerprint "$b" || { fail "Invalid identity fingerprint on line $line_no."; return 1; }
                valid_identity_type "$c" || { fail "Invalid identity type on line $line_no."; return 1; }
                valid_identity_status "$d" || { fail "Invalid identity status on line $line_no."; return 1; }
                for i in "${!IMPORT_ID_NAMES[@]}"; do
                    [[ "${IMPORT_ID_NAMES[$i]}" == "$a" ]] && { fail "Duplicate identity name '$a' in import."; return 1; }
                    [[ "${IMPORT_ID_FINGERPRINTS[$i]}" == "$b" ]] && { fail "Duplicate identity fingerprint '$b' in import."; return 1; }
                done
                IMPORT_ID_NAMES+=("$a")
                IMPORT_ID_FINGERPRINTS+=("$b")
                IMPORT_ID_TYPES+=("$c")
                IMPORT_ID_STATUSES+=("$d")
                ;;
            POLICY)
                [[ -z "${c:-}" && -z "${d:-}" && -z "${extra:-}" && -n "$a" && -n "$b" ]] || {
                    fail "Invalid policy record on line $line_no."; return 1;
                }
                valid_fingerprint "$a" || { fail "Invalid policy fingerprint on line $line_no."; return 1; }
                [[ "$b" != *'|'* ]] || { fail "Invalid policy machine on line $line_no."; return 1; }
                for i in "${!IMPORT_POLICY_FINGERPRINTS[@]}"; do
                    if [[ "${IMPORT_POLICY_FINGERPRINTS[$i]}" == "$a" && "${IMPORT_POLICY_HOSTS[$i]}" == "$b" ]]; then
                        fail "Duplicate policy rule '$a -> $b' in import."
                        return 1
                    fi
                done
                IMPORT_POLICY_FINGERPRINTS+=("$a")
                IMPORT_POLICY_HOSTS+=("$b")
                ;;
            *) fail "Unknown trust config record '$kind' on line $line_no."; return 1 ;;
        esac
    done < "$path"

    (( line_no > 0 )) || { fail "Trust config is empty."; return 1; }
    for i in "${!IMPORT_POLICY_FINGERPRINTS[@]}"; do
        identity_idx=$(import_identity_index_by_fingerprint "${IMPORT_POLICY_FINGERPRINTS[$i]}") || {
            fail "Policy references an identity fingerprint not present in the imported registry: ${IMPORT_POLICY_FINGERPRINTS[$i]}"
            return 1
        }
        [[ "${IMPORT_ID_STATUSES[$identity_idx]}" == "active" ]] || {
            fail "Policy references retired identity '${IMPORT_ID_NAMES[$identity_idx]}'."
            return 1
        }
        host_index "${IMPORT_POLICY_HOSTS[$i]}" >/dev/null 2>&1 || {
            fail "Policy references unknown local machine alias '${IMPORT_POLICY_HOSTS[$i]}'."
            return 1
        }
    done
}

config_with_source() {
    local operation="$1" source="$2" tmp="" rc
    local path="$source"
    if [[ "$source" == "-" ]]; then
        tmp=$(mktemp "$CONFIG_DIR/trust-import.XXXXXX") || return 1
        cat > "$tmp"
        chmod 600 "$tmp" 2>/dev/null || true
        path="$tmp"
    fi
    case "$operation" in
        validate)
            if config_parse_file "$path"; then
                ok "Valid trust configuration: ${#IMPORT_ID_NAMES[@]} identities, ${#IMPORT_POLICY_FINGERPRINTS[@]} policy rules."
                rc=0
            else
                rc=1
            fi
            ;;
        import)
            if config_parse_file "$path"; then
                config_import_parsed
                rc=$?
            else
                rc=1
            fi
            ;;
        *) rc=1 ;;
    esac
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return "$rc"
}

config_validate() { config_with_source validate "$1"; }
config_import() { config_with_source import "$1"; }

config_import_parsed() {
    local id_tmp policy_tmp i stamp suffix id_backup policy_backup
    [[ ! -L "$IDENTITIES_FILE" ]] || { fail "Refusing to import over symlinked identity registry."; return 1; }
    [[ ! -L "$POLICY_FILE" ]] || { fail "Refusing to import over symlinked policy file."; return 1; }
    id_tmp=$(mktemp "$CONFIG_DIR/identities.import.XXXXXX") || return 1
    policy_tmp=$(mktemp "$CONFIG_DIR/policy.import.XXXXXX") || { rm -f "$id_tmp"; return 1; }
    chmod 600 "$id_tmp" "$policy_tmp" 2>/dev/null || true

    for i in "${!IMPORT_ID_NAMES[@]}"; do
        printf '%s|%s|%s|%s\n' "${IMPORT_ID_NAMES[$i]}" "${IMPORT_ID_FINGERPRINTS[$i]}" \
            "${IMPORT_ID_TYPES[$i]}" "${IMPORT_ID_STATUSES[$i]}" >> "$id_tmp"
    done
    for i in "${!IMPORT_POLICY_FINGERPRINTS[@]}"; do
        printf '%s|%s\n' "${IMPORT_POLICY_FINGERPRINTS[$i]}" "${IMPORT_POLICY_HOSTS[$i]}" >> "$policy_tmp"
    done

    stamp=$(date +%Y%m%d-%H%M%S)
    suffix="pre-import-$stamp-$$"
    id_backup="$IDENTITIES_FILE.$suffix"
    policy_backup="$POLICY_FILE.$suffix"
    cp -p "$IDENTITIES_FILE" "$id_backup" || { rm -f "$id_tmp" "$policy_tmp"; fail "Could not back up identity registry."; return 1; }
    cp -p "$POLICY_FILE" "$policy_backup" || { rm -f "$id_tmp" "$policy_tmp" "$id_backup"; fail "Could not back up policy."; return 1; }
    chmod 600 "$id_backup" "$policy_backup" 2>/dev/null || true

    if ! mv -f "$id_tmp" "$IDENTITIES_FILE"; then
        rm -f "$policy_tmp"
        fail "Could not replace identity registry."
        return 1
    fi
    if ! mv -f "$policy_tmp" "$POLICY_FILE"; then
        cp -p "$id_backup" "$IDENTITIES_FILE" || true
        cp -p "$policy_backup" "$POLICY_FILE" || true
        fail "Could not replace policy; previous configuration restored."
        return 1
    fi
    chmod 600 "$IDENTITIES_FILE" "$POLICY_FILE" 2>/dev/null || true
    prune_backups "$IDENTITIES_FILE"
    prune_backups "$POLICY_FILE"
    ok "Imported ${#IMPORT_ID_NAMES[@]} identities and ${#IMPORT_POLICY_FINGERPRINTS[@]} policy rules."
    info "Backups: $id_backup and $policy_backup"
}

sync_remote_identity_index_by_fingerprint() {
    local wanted="$1" i
    for i in "${!SYNC_REMOTE_ID_FINGERPRINTS[@]}"; do
        [[ "${SYNC_REMOTE_ID_FINGERPRINTS[$i]}" == "$wanted" ]] && { printf '%s' "$i"; return 0; }
    done
    return 1
}

sync_parse_remote_state() {
    local state="$1" line line_no=0 kind a b c d extra i
    SYNC_REMOTE_ID_NAMES=() SYNC_REMOTE_ID_FINGERPRINTS=() SYNC_REMOTE_ID_TYPES=() SYNC_REMOTE_ID_STATUSES=()
    SYNC_REMOTE_POLICY_FINGERPRINTS=() SYNC_REMOTE_POLICY_HOSTS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        if (( line_no == 1 )); then
            [[ "$line" == "SKM-REMOTE-TRUST|1" ]] || { fail "Remote SKM trust metadata has an invalid header."; return 1; }
            continue
        fi
        [[ -n "$line" ]] || continue
        IFS='|' read -r kind a b c d extra <<< "$line"
        case "$kind" in
            IDENTITY)
                [[ -z "${extra:-}" && -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || { fail "Remote identity registry is malformed."; return 1; }
                if ! valid_name "$a" || ! valid_fingerprint "$b" || ! valid_identity_type "$c" || ! valid_identity_status "$d"; then
                    fail "Remote identity registry contains invalid metadata."
                    return 1
                fi
                for i in "${!SYNC_REMOTE_ID_FINGERPRINTS[@]}"; do
                    [[ "${SYNC_REMOTE_ID_NAMES[$i]}" != "$a" && "${SYNC_REMOTE_ID_FINGERPRINTS[$i]}" != "$b" ]] || { fail "Remote identity registry contains duplicates."; return 1; }
                done
                SYNC_REMOTE_ID_NAMES+=("$a"); SYNC_REMOTE_ID_FINGERPRINTS+=("$b"); SYNC_REMOTE_ID_TYPES+=("$c"); SYNC_REMOTE_ID_STATUSES+=("$d")
                ;;
            POLICY)
                [[ -z "${c:-}" && -z "${d:-}" && -z "${extra:-}" && -n "$a" && -n "$b" ]] || { fail "Remote policy metadata is malformed."; return 1; }
                valid_fingerprint "$a" || { fail "Remote policy contains an invalid fingerprint."; return 1; }
                SYNC_REMOTE_POLICY_FINGERPRINTS+=("$a"); SYNC_REMOTE_POLICY_HOSTS+=("$b")
                ;;
            *) fail "Remote trust metadata contains unknown record '$kind'."; return 1 ;;
        esac
    done <<< "$state"
    (( line_no > 0 )) || { fail "Remote SKM trust metadata is empty."; return 1; }
}

sync_policy_impact_count() {
    local i idx count=0
    for i in "${!SYNC_REMOTE_POLICY_FINGERPRINTS[@]}"; do
        if ! idx=$(identity_index_by_fingerprint "${SYNC_REMOTE_POLICY_FINGERPRINTS[$i]}"); then
            count=$((count + 1))
        elif [[ "${IDENTITY_STATUSES[$idx]}" != "active" ]]; then
            count=$((count + 1))
        fi
    done
    printf '%s' "$count"
}

sync_print_plan() {
    local machine="$1" i remote_idx action impact
    say "Identity sync plan — $machine"
    printf '%-10s %-24s %s\n' ACTION IDENTITY FINGERPRINT
    for i in "${!IDENTITY_NAMES[@]}"; do
        if remote_idx=$(sync_remote_identity_index_by_fingerprint "${IDENTITY_FINGERPRINTS[$i]}"); then
            if [[ "${SYNC_REMOTE_ID_NAMES[$remote_idx]}" == "${IDENTITY_NAMES[$i]}" && \
                  "${SYNC_REMOTE_ID_TYPES[$remote_idx]}" == "${IDENTITY_TYPES[$i]}" && \
                  "${SYNC_REMOTE_ID_STATUSES[$remote_idx]}" == "${IDENTITY_STATUSES[$i]}" ]]; then
                action="UNCHANGED"
            else
                action="UPDATE"
            fi
        else
            action="ADD"
        fi
        printf '%-10s %-24s %s\n' "$action" "${IDENTITY_NAMES[$i]}" "${IDENTITY_FINGERPRINTS[$i]}"
    done
    for i in "${!SYNC_REMOTE_ID_NAMES[@]}"; do
        if ! identity_index_by_fingerprint "${SYNC_REMOTE_ID_FINGERPRINTS[$i]}" >/dev/null 2>&1; then
            printf '%-10s %-24s %s\n' REMOVE "${SYNC_REMOTE_ID_NAMES[$i]}" "${SYNC_REMOTE_ID_FINGERPRINTS[$i]}"
        fi
    done
    impact=$(sync_policy_impact_count)
    if (( impact > 0 )); then
        warn "$impact remote policy rule(s) would reference an identity that is missing or retired after sync."
    else
        ok "Remote desired-state policy remains valid after this identity sync."
    fi
}

sync_identities() {
    local machine="$1" mode="${2:-}" index i payload="" output state impact
    [[ -z "$mode" || "$mode" == "--dry-run" ]] || { fail "Usage: skm sync identities MACHINE [--dry-run]"; return 2; }
    require_host "$machine" || return 1
    index=$RESOLVED_HOST_INDEX
    is_local_host "$index" && { fail "Identity sync target must be a remote machine."; return 1; }
    load_identities
    (( ${#IDENTITY_NAMES[@]} > 0 )) || { fail "Identity registry is empty; refusing to replace remote registry."; return 1; }

    state=$(ssh_run_batch "$index" "$REMOTE_TRUST_STATE_SCRIPT") || { fail "Could not read remote SKM trust metadata from $machine."; return 1; }
    sync_parse_remote_state "$state" || return 1
    sync_print_plan "$machine"
    impact=$(sync_policy_impact_count)
    if [[ "$mode" == "--dry-run" ]]; then
        (( impact == 0 )) || return 1
        info "Dry run only; no remote files were changed."
        return 0
    fi
    if (( impact > 0 )); then
        fail "Identity sync refused because it would invalidate remote desired-state policy. Update the remote policy first."
        return 1
    fi

    for i in "${!IDENTITY_NAMES[@]}"; do
        payload="${payload}${payload:+$'\n'}${IDENTITY_NAMES[$i]}|${IDENTITY_FINGERPRINTS[$i]}|${IDENTITY_TYPES[$i]}|${IDENTITY_STATUSES[$i]}"
    done
    if output=$(ssh_run_batch "$index" "$REMOTE_IDENTITIES_SYNC_SCRIPT" <<< "$payload"); then
        ok "Synced ${#IDENTITY_NAMES[@]} identities to $machine."
        info "Remote result: $(sanitize_text "$output")"
        info "Policy was not synchronized; desired-state rules remain local to each SKM node."
    else
        fail "Could not synchronize identity registry to $machine."
        return 1
    fi
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

json_command_result() {
    local command_name="$1" rc="$2" output="$3" line issue first=1 issue_count=0
    local issues=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "warn  "* || "$line" == "error "* ]]; then
            if [[ "$line" =~ ^warn[[:space:]]+[0-9]+[[:space:]]+(trust|policy)[[:space:]] ]]; then
                continue
            fi
            issue="${line#warn  }"
            issue="${issue#error }"
            if (( first == 0 )); then issues="$issues,"; fi
            issues="$issues\"$(json_escape "$issue")\""
            first=0
            issue_count=$((issue_count + 1))
        fi
    done <<< "$output"
    printf '{"command":"%s","version":"%s","ok":%s,"exit_code":%d,"issue_count":%d,"issues":[%s]}\n' \
        "$(json_escape "$command_name")" "$(json_escape "$VERSION")" \
        "$([[ "$rc" == "0" ]] && printf true || printf false)" "$rc" "$issue_count" "$issues"
}

audit_json() {
    local output rc=0
    local C_ACCENT="" C_SILVER="" C_MUTED="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_BOLD="" C_RESET=""
    output=$(audit 2>&1) || rc=$?
    json_command_result audit "$rc" "$output"
    return "$rc"
}

policy_check_json() {
    local output rc=0
    local C_ACCENT="" C_SILVER="" C_MUTED="" C_DIM="" C_GREEN="" C_YELLOW="" C_RED="" C_BOLD="" C_RESET=""
    output=$(policy_check 2>&1) || rc=$?
    json_command_result policy-check "$rc" "$output"
    return "$rc"
}
