# shellcheck shell=bash

key_type() { awk '{print $1}' <<< "$1"; }
key_algorithm() {
    awk '{ for (i=1; i<=NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i; exit } }' <<< "$1"
}
key_blob() {
    awk '{ for (i=1; i<=NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/ && i < NF) { print $(i+1); exit } }' <<< "$1"
}
key_comment() {
    awk '{ for (i=1; i<=NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/ && i < NF) { if (i+1 < NF) { for (j=i+2; j<=NF; j++) printf "%s%s", (j==i+2?"":" "), $j }; exit } }' <<< "$1"
}
key_fingerprint() {
    local algorithm blob
    algorithm=$(key_algorithm "$1"); blob=$(key_blob "$1")
    [[ -n "$algorithm" && -n "$blob" ]] || return 1
    printf '%s %s\n' "$algorithm" "$blob" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}'
}

valid_public_key() {
    local line="$1" type
    [[ "$line" != *$'\n'* ]] || return 1
    type=$(key_type "$line")
    [[ "$type" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$ ]] || return 1
    [[ -n "$(key_blob "$line")" ]] || return 1
    printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1
}

read_public_key_file() {
    local path="$1" line
    [[ -f "$path" && ! -L "$path" ]] || { fail "Public key file not found or unsafe: $path"; return 1; }
    IFS= read -r line < "$path" || true
    valid_public_key "$line" || { fail "Invalid or unsupported public key: $path"; return 1; }
    printf '%s' "$line"
}

key_path_is_safe() {
    local path="$1" relative
    [[ "$path" == "$SSH_DIR/"* ]] || return 1
    relative="${path#"$SSH_DIR/"}"
    [[ -n "$relative" && "$relative" != "." && "$relative" != ".." && "$relative" != */* ]]
}

ensure_managed_key() {
    key_path_is_safe "$MANAGED_KEY" || { fail "Managed key must be a direct child of $SSH_DIR."; return 1; }
    if [[ -f "$MANAGED_KEY.pub" && -f "$MANAGED_KEY" ]]; then
        [[ ! -L "$MANAGED_KEY" && ! -L "$MANAGED_KEY.pub" ]] || { fail "Managed keypair must not use symlinks: $MANAGED_KEY"; return 1; }
        chmod 600 "$MANAGED_KEY" 2>/dev/null || true
        chmod 644 "$MANAGED_KEY.pub" 2>/dev/null || true
        printf '%s' "$MANAGED_KEY.pub"
        return 0
    fi
    [[ ! -e "$MANAGED_KEY" && ! -e "$MANAGED_KEY.pub" ]] || { fail "Managed keypair is incomplete: $MANAGED_KEY"; return 1; }
    mkdir -p "$SSH_DIR" || { fail "Cannot create $SSH_DIR."; return 1; }
    chmod 700 "$SSH_DIR" 2>/dev/null || true
    info "Creating a dedicated ED25519 key for SKM (private key stays on this machine)." >&2
    ssh-keygen -q -t ed25519 -N '' -C "skm@$(hostname 2>/dev/null || printf local)" -f "$MANAGED_KEY" || { fail "Could not generate managed key."; return 1; }
    chmod 600 "$MANAGED_KEY"; chmod 644 "$MANAGED_KEY.pub"
    printf '%s' "$MANAGED_KEY.pub"
}

acquire_auth_lock() {
    local lock="$SSH_DIR/.skm-authorized-keys.lock" attempt=0
    while ! mkdir "$lock" 2>/dev/null; do
        attempt=$((attempt + 1))
        (( attempt < 30 )) || return 1
        sleep 0.1
    done
}
release_auth_lock() { rmdir "$SSH_DIR/.skm-authorized-keys.lock" 2>/dev/null || true; }

authorized_add_local() {
    local line="$1" blob tmp result="added"
    valid_public_key "$line" || return 2
    blob=$(key_blob "$line")
    mkdir -p "$SSH_DIR" || return 1
    chmod 700 "$SSH_DIR" 2>/dev/null || true
    [[ ! -L "$AUTHORIZED_KEYS" ]] || { fail "$AUTHORIZED_KEYS is a symlink; refusing to replace it."; return 1; }
    acquire_auth_lock || { fail "Another authorized_keys update is in progress."; return 1; }
    tmp=$(mktemp "$SSH_DIR/authorized_keys.skm.XXXXXX") || { release_auth_lock; return 1; }
    [[ -f "$AUTHORIZED_KEYS" ]] && cat "$AUTHORIZED_KEYS" > "$tmp"
    if awk -v wanted="$blob" '{ for (i=1; i<=NF; i++) if ($i == wanted) found=1 } END { exit !found }' "$tmp"; then
        result="exists"
    else
        printf '%s\n' "$line" >> "$tmp"
    fi
    chmod 600 "$tmp"
    if [[ -f "$AUTHORIZED_KEYS" ]]; then cp -p "$AUTHORIZED_KEYS" "$AUTHORIZED_KEYS.skm.bak" 2>/dev/null || true; fi
    mv -f "$tmp" "$AUTHORIZED_KEYS"
    release_auth_lock
    printf '%s' "$result"
}

authorized_remove_local() {
    local blob="$1" tmp
    [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]] || return 1
    acquire_auth_lock || return 1
    tmp=$(mktemp "$SSH_DIR/authorized_keys.skm.XXXXXX") || { release_auth_lock; return 1; }
    awk -v wanted="$blob" '{ found=0; for (i=1; i<=NF; i++) if ($i == wanted) found=1; if (!found) print }' "$AUTHORIZED_KEYS" > "$tmp"
    chmod 600 "$tmp"
    cp -p "$AUTHORIZED_KEYS" "$AUTHORIZED_KEYS.skm.bak" 2>/dev/null || true
    mv -f "$tmp" "$AUTHORIZED_KEYS"
    release_auth_lock
}

remote_add_authorized() {
    local index="$1" line="$2"
    if is_local_host "$index"; then authorized_add_local "$line"; return; fi
    printf '%s\n' "$line" | ssh_run "$index" "$REMOTE_ADD_SCRIPT"
}

remote_remove_authorized() {
    local index="$1" blob="$2"
    if is_local_host "$index"; then authorized_remove_local "$blob"; return; fi
    printf '%s\n' "$blob" | ssh_run "$index" "$REMOTE_REMOVE_SCRIPT"
}

remote_authorized_keys() {
    local index="$1"
    if is_local_host "$index"; then [[ -f "$AUTHORIZED_KEYS" ]] && cat "$AUTHORIZED_KEYS"; return 0; fi
    # shellcheck disable=SC2016
    ssh_run_batch "$index" 'test ! -L "$HOME/.ssh/authorized_keys" || exit 20; cat "$HOME/.ssh/authorized_keys" 2>/dev/null || true'
}

remote_public_keys() {
    local index="$1" file line
    if [[ "$index" == "local" ]] || is_local_host "$index"; then
        shopt -s nullglob
        for file in "$SSH_DIR"/*.pub; do
            [[ -f "$file" && ! -L "$file" ]] || continue
            line=$(read_public_key_file "$file" 2>/dev/null || true)
            [[ -n "$line" ]] && printf '%s\n' "$line"
        done
        shopt -u nullglob
        return 0
    fi
    # Read only public key files. Private key paths and contents never leave the machine.
    # shellcheck disable=SC2016
    ssh_run_batch "$index" 'for file in "$HOME"/.ssh/*.pub; do
  [ -f "$file" ] && [ ! -L "$file" ] || continue
  IFS= read -r line < "$file" || true
  [ -n "$line" ] && printf "%s\n" "$line"
done'
}

remote_managed_public_key() {
    local index="$1" path
    if is_local_host "$index"; then
        path=$(ensure_managed_key) || return 1
        read_public_key_file "$path"
        return
    fi
    # shellcheck disable=SC2016
    ssh_run "$index" 'set -eu
umask 077
mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
key="$HOME/.ssh/id_ed25519_skm"
if [ ! -f "$key" ] || [ ! -f "$key.pub" ]; then
  [ ! -e "$key" ] && [ ! -e "$key.pub" ] || { echo "incomplete managed key" >&2; exit 23; }
  command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen missing" >&2; exit 24; }
  ssh-keygen -q -t ed25519 -N "" -C "skm@$(hostname 2>/dev/null || echo remote)" -f "$key"
fi
chmod 600 "$key"; chmod 644 "$key.pub"
cat "$key.pub"'
}

remote_read_managed_public_key() {
    local index="$1"
    if is_local_host "$index"; then
        [[ -f "$MANAGED_KEY.pub" ]] && read_public_key_file "$MANAGED_KEY.pub"
        return 0
    fi
    # shellcheck disable=SC2016
    ssh_run_batch "$index" 'key="$HOME/.ssh/id_ed25519_skm.pub"; [ -f "$key" ] && [ ! -L "$key" ] && cat "$key" || true'
}

access_grant_public_key() {
    local name="$1" key="$2" index result
    valid_public_key "$key" || { fail "Invalid or unsupported public key."; return 1; }
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    info "Authorizing the selected public key on ${HOST_NAMES[$index]}."
    info "Only the public key is added; a server password may be requested once."
    result=$(remote_add_authorized "$index" "$key") || {
        fail "Could not authorize the key on ${HOST_NAMES[$index]}."
        say "Public key for manual installation:"
        say "$key"
        return 1
    }
    if [[ "$result" == *exists* ]]; then
        ok "Access already existed: this device is authorized on ${HOST_NAMES[$index]}."
    else
        ok "Access granted: the device can now sign in to ${HOST_NAMES[$index]}."
    fi
}

access_grant() {
    local name="$1" pub_path="${2:-}" key
    if [[ -z "$pub_path" ]]; then pub_path=$(ensure_managed_key) || return 1; fi
    key=$(read_public_key_file "$pub_path") || return 1
    access_grant_public_key "$name" "$key"
}

access_receive() {
    local name="$1" index remote_key result
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    info "Direction: ${HOST_NAMES[$index]} -> this machine"
    info "The remote machine keeps its private key; only its public key is read."
    remote_key=$(remote_managed_public_key "$index") || { fail "Could not obtain the remote machine's managed public key."; return 1; }
    valid_public_key "$remote_key" || { fail "Remote machine returned an invalid public key."; return 1; }
    result=$(authorized_add_local "$remote_key") || { fail "Could not update local authorized_keys."; return 1; }
    if [[ "$result" == "exists" ]]; then
        ok "Access already existed: ${HOST_NAMES[$index]} can sign in to this machine."
    else
        ok "Access granted: ${HOST_NAMES[$index]} can now sign in to this machine."
    fi
}

access_link() {
    local name="$1"
    say "Two-way setup keeps a separate private key on each machine."
    say "Step 1/2: allow this machine to connect to $name."
    access_grant "$name" "${2:-}" || return 1
    say "Step 2/2: allow $name to connect back to this machine."
    access_receive "$name" || return 1
    ok "Two-way passwordless access is ready with $name."
}

blob_is_authorized() {
    local blob="$1" lines="$2"
    awk -v wanted="$blob" '{ for (i=1; i<=NF; i++) if ($i == wanted) found=1 } END { exit !found }' <<< "$lines"
}

access_status_one() {
    local name="$1" index local_key local_blob remote_auth remote_key remote_blob local_auth=""
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    printf '\n%s%s%s\n' "$C_BOLD" "${HOST_NAMES[$index]} (${HOST_USERS[$index]}@${HOST_ADDRS[$index]})" "$C_RESET"
    if is_local_host "$index"; then
        printf '  %s● this machine%s (no SSH connection needed)\n' "$C_GREEN" "$C_RESET"
        return 0
    fi
    if ! ssh_run_batch "$index" true >/dev/null 2>&1; then
        printf '  this machine -> %-18s %sunknown%s (no key-based connection)\n' "${HOST_NAMES[$index]}" "$C_YELLOW" "$C_RESET"
        printf '  %-18s -> this machine  %sunknown%s\n' "${HOST_NAMES[$index]}" "$C_YELLOW" "$C_RESET"
        return 1
    fi
    if [[ -f "$MANAGED_KEY.pub" ]]; then
        local_key=$(read_public_key_file "$MANAGED_KEY.pub"); local_blob=$(key_blob "$local_key")
        remote_auth=$(remote_authorized_keys "$index" 2>/dev/null || true)
        if blob_is_authorized "$local_blob" "$remote_auth"; then
            printf '  this machine -> %-18s %sready%s\n' "${HOST_NAMES[$index]}" "$C_GREEN" "$C_RESET"
        else
            printf '  this machine -> %-18s %snot granted%s\n' "${HOST_NAMES[$index]}" "$C_RED" "$C_RESET"
        fi
    else
        printf '  this machine -> %-18s %sno SKM key%s\n' "${HOST_NAMES[$index]}" "$C_YELLOW" "$C_RESET"
    fi
    remote_key=$(remote_read_managed_public_key "$index" 2>/dev/null || true)
    [[ -f "$AUTHORIZED_KEYS" ]] && local_auth=$(cat "$AUTHORIZED_KEYS")
    if valid_public_key "$remote_key"; then
        remote_blob=$(key_blob "$remote_key")
        if blob_is_authorized "$remote_blob" "$local_auth"; then
            printf '  %-18s -> this machine  %sready%s\n' "${HOST_NAMES[$index]}" "$C_GREEN" "$C_RESET"
        else
            printf '  %-18s -> this machine  %snot granted%s\n' "${HOST_NAMES[$index]}" "$C_RED" "$C_RESET"
        fi
    else
        printf '  %-18s -> this machine  %sno SKM key%s\n' "${HOST_NAMES[$index]}" "$C_YELLOW" "$C_RESET"
    fi
}

access_status() {
    if [[ -n "${1:-}" ]]; then access_status_one "$1"; return; fi
    local i rc=0
    (( ${#HOST_NAMES[@]} > 0 )) || { say "No machines saved."; return 0; }
    for i in "${!HOST_NAMES[@]}"; do access_status_one "${HOST_NAMES[$i]}" || rc=1; done
    return "$rc"
}

print_authorized_lines() {
    local lines="$1" n=0 line fp comment
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        n=$((n + 1))
        comment=$(key_display_label "$fp" "$(key_comment "$line")")
        printf '%3d  %-28s %s\n' "$n" "$comment" "$fp"
    done <<< "$lines"
}

print_inventory_lines() {
    local lines="$1" n=0 line fp comment algorithm
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        algorithm=$(key_algorithm "$line")
        comment=$(key_display_label "$fp" "$(key_comment "$line")")
        (( ${#comment} > 28 )) && comment="${comment:0:27}…"
        n=$((n + 1))
        printf '    %-12s %-48s %s\n' "$algorithm" "$fp" "$comment"
    done <<< "$lines"
    (( n > 0 )) || say "    none"
}

authorized_key_menu_item() {
    local line="$1" fingerprint algorithm comment
    fingerprint=$(key_fingerprint "$line") || return 1
    algorithm=$(key_algorithm "$line")
    comment=$(key_display_label "$fingerprint" "$(key_comment "$line")")
    (( ${#comment} > 42 )) && comment="${comment:0:41}…"
    printf '%s|%s · %s' "$comment" "$algorithm" "$fingerprint"
}

choose_authorized_line() {
    local lines="$1" choice line n=0
    print_authorized_lines "$lines"
    choice=$(prompt "Key number to revoke") || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ -n "$(key_fingerprint "$line")" ]] || continue
        n=$((n + 1)); if (( n == choice )); then printf '%s' "$line"; return 0; fi
    done <<< "$lines"
    return 1
}

access_revoke_remote() {
    local name="$1" index lines selected
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    lines=$(remote_authorized_keys "$index") || { fail "Cannot read authorized keys on $name."; return 1; }
    [[ -n "$lines" ]] || { fail "No authorized keys found on $name."; return 1; }
    say "These keys can sign in to $name:"
    selected=$(choose_authorized_line "$lines") || { fail "Invalid selection."; return 1; }
    confirm "Revoke $(key_fingerprint "$selected") from $name?" || { say "Cancelled."; return 0; }
    access_revoke_key "$name" "$selected"
}

access_revoke_key() {
    local name="$1" selected="$2" index blob fingerprint
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    blob=$(key_blob "$selected"); fingerprint=$(key_fingerprint "$selected")
    [[ -n "$blob" && -n "$fingerprint" ]] || { fail "Invalid authorized key selection."; return 1; }
    remote_remove_authorized "$index" "$blob" || { fail "Could not revoke access."; return 1; }
    ok "Access revoked on $name. Backup: ~/.ssh/authorized_keys.skm.bak"
}

access_allow_local() {
    local source="${1:--}" line
    if [[ "$source" == "-" ]]; then
        [[ -t 0 ]] && printf 'Paste one public key, then press Enter:\n' >&2
        IFS= read -r line || { fail "No public key received."; return 1; }
    else
        line=$(read_public_key_file "$source") || return 1
    fi
    access_allow_public_key "$line"
}

access_allow_public_key() {
    local line="$1" result
    valid_public_key "$line" || { fail "Invalid or unsupported public key."; return 1; }
    result=$(authorized_add_local "$line") || { fail "Could not update local authorized_keys."; return 1; }
    if [[ "$result" == "exists" ]]; then ok "That device already had access to this machine."; else ok "Access granted to this machine."; fi
}


key_inventory_machine() {
    local label="$1" index="${2:-}" owned="" allowed="" allowed_unavailable=0
    printf '\n%s◆ %s%s\n' "$C_BOLD" "$label" "$C_RESET"
    if [[ -z "$index" ]]; then
        owned=$(remote_public_keys local 2>/dev/null || true)
        [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]] && allowed=$(cat "$AUTHORIZED_KEYS")
    else
        owned=$(remote_public_keys "$index" 2>/dev/null) || {
            printf '  %sunavailable%s  Public keys could not be read with current access.\n' "$C_YELLOW" "$C_RESET"
            return 1
        }
        allowed=$(remote_authorized_keys "$index" 2>/dev/null) || { allowed=""; allowed_unavailable=1; }
    fi
    say "  Public identities on this machine"
    print_inventory_lines "$owned"
    say "  Keys allowed to access this machine"
    if (( allowed_unavailable == 1 )); then
        printf '    %sunavailable%s\n' "$C_YELLOW" "$C_RESET"
    else
        print_inventory_lines "$allowed"
    fi
}

key_list() {
    local i local_label="This machine" local_seen=0 rc=0
    for i in "${!HOST_NAMES[@]}"; do
        if is_local_host "$i"; then local_label="${HOST_NAMES[$i]} · this machine"; local_seen=1; break; fi
    done
    say "Public key inventory — private keys are never read or displayed."
    key_inventory_machine "$local_label" || rc=1
    for i in "${!HOST_NAMES[@]}"; do
        is_local_host "$i" && continue
        key_inventory_machine "${HOST_NAMES[$i]} · ${HOST_USERS[$i]}@${HOST_ADDRS[$i]}" "$i" || rc=1
    done
    (( local_seen == 1 || ${#HOST_NAMES[@]} > 0 )) || say "\nAdd a machine to include its public key inventory."
    return "$rc"
}

key_generate() {
    local path="${1:-$MANAGED_KEY}" comment="${2:-skm@$(hostname 2>/dev/null || printf local)}" clean_comment
    key_path_is_safe "$path" || { fail "Key must be created as a direct child of $SSH_DIR."; return 1; }
    clean_comment=$(sanitize_text "$comment")
    [[ "$clean_comment" == "$comment" ]] || { fail "Key comment contains unsafe control characters."; return 1; }
    [[ ! -e "$path" && ! -e "$path.pub" ]] || { fail "Key already exists: $path"; return 1; }
    mkdir -p "$SSH_DIR" || { fail "Cannot create $SSH_DIR."; return 1; }
    chmod 700 "$SSH_DIR" 2>/dev/null || true
    ssh-keygen -t ed25519 -a 64 -f "$path" -C "$comment" || { fail "Key generation failed."; return 1; }
    chmod 600 "$path"; chmod 644 "$path.pub"
    ok "Created $path and $path.pub."
}

key_public() {
    local path="${1:-}"
    if [[ -z "$path" ]]; then path=$(ensure_managed_key) || return 1; fi
    read_public_key_file "$path" || return 1; say ""
}

doctor_file_mode() {
    local path="$1" expected="$2" label="$3" mode
    [[ -e "$path" ]] || return 0
    if [[ -L "$path" ]]; then
        fail "$label is a symlink: $path"
        return 1
    fi
    mode=$(file_mode "$path" 2>/dev/null || true)
    if [[ "$mode" == "$expected" ]]; then
        ok "$label permissions: $expected"
        return 0
    fi
    warn "$label permissions should be $expected (found ${mode:-unknown})."
    return 1
}

doctor() {
    local issues=0 mode line type i pinned=0 unpinned=0
    say "$APP_NAME trust health check"

    command -v ssh >/dev/null 2>&1 && ok "OpenSSH client: available" || { fail "OpenSSH client is missing."; issues=$((issues+1)); }
    command -v ssh-keygen >/dev/null 2>&1 && ok "ssh-keygen: available" || { fail "ssh-keygen is missing."; issues=$((issues+1)); }
    command -v curl >/dev/null 2>&1 && ok "curl: available for updates" || info "curl is unavailable; remote update checks/install will not work."

    if [[ -d "$CONFIG_DIR" ]]; then
        mode=$(file_mode "$CONFIG_DIR" 2>/dev/null || true)
        if [[ "$mode" == "700" ]]; then ok "SKM config directory permissions: 700"; else warn "SKM config directory permissions should be 700 (found ${mode:-unknown})."; issues=$((issues+1)); fi
    else
        warn "$CONFIG_DIR does not exist yet."
    fi
    doctor_file_mode "$HOSTS_FILE" 600 "machine registry" || issues=$((issues+1))
    doctor_file_mode "$IDENTITIES_FILE" 600 "identity registry" || issues=$((issues+1))
    doctor_file_mode "$POLICY_FILE" 600 "desired-state policy" || issues=$((issues+1))
    doctor_file_mode "$KNOWN_HOSTS_FILE" 600 "SKM known_hosts" || issues=$((issues+1))
    doctor_file_mode "$SETTINGS_FILE" 600 "SKM settings" || issues=$((issues+1))

    if [[ -d "$SSH_DIR" ]]; then
        mode=$(file_mode "$SSH_DIR" 2>/dev/null || true)
        if [[ "$mode" == "700" ]]; then ok "$SSH_DIR permissions: 700"; else warn "$SSH_DIR permissions should be 700 (found ${mode:-unknown})."; issues=$((issues+1)); fi
    else
        warn "$SSH_DIR does not exist yet."
    fi

    if [[ -e "$MANAGED_KEY" || -e "$MANAGED_KEY.pub" ]]; then
        if [[ -f "$MANAGED_KEY" && -f "$MANAGED_KEY.pub" && ! -L "$MANAGED_KEY" && ! -L "$MANAGED_KEY.pub" ]]; then
            doctor_file_mode "$MANAGED_KEY" 600 "managed private key" || issues=$((issues+1))
            doctor_file_mode "$MANAGED_KEY.pub" 644 "managed public key" || issues=$((issues+1))
        else
            fail "Managed keypair is incomplete or uses a symlink: $MANAGED_KEY"
            issues=$((issues+1))
        fi
    else
        info "Managed SKM keypair has not been created yet."
    fi

    if [[ -f "$AUTHORIZED_KEYS" || -L "$AUTHORIZED_KEYS" ]]; then
        doctor_file_mode "$AUTHORIZED_KEYS" 600 "authorized_keys" || issues=$((issues+1))
        if [[ -f "$AUTHORIZED_KEYS" && ! -L "$AUTHORIZED_KEYS" ]]; then
            while IFS= read -r line; do
                type=$(key_algorithm "$line")
                if [[ "$type" == "ssh-rsa" || "$type" == "ssh-dss" ]]; then
                    warn "Legacy authorized key type: $type ($(key_fingerprint "$line"))"
                    issues=$((issues+1))
                fi
            done < "$AUTHORIZED_KEYS"
        fi
    fi

    load_identities
    load_policy
    ok "Identity registry: ${#IDENTITY_NAMES[@]} registered"
    if (( ${#POLICY_FINGERPRINTS[@]} > 0 )); then ok "Desired-state policy: ${#POLICY_FINGERPRINTS[@]} rule(s)"; else info "Desired-state policy is empty."; fi

    for i in "${!HOST_NAMES[@]}"; do
        is_local_host "$i" && continue
        if host_has_pin "$i"; then
            pinned=$((pinned + 1))
            ok "${HOST_NAMES[$i]}: SSH host key is pinned"
        else
            unpinned=$((unpinned + 1))
            warn "${HOST_NAMES[$i]}: SSH host key is not pinned; connection uses $STRICT_HOST_KEY_CHECKING trust mode."
        fi
    done
    info "Host trust: $pinned pinned, $unpinned unpinned remote machine(s)."

    if command -v gh >/dev/null 2>&1 && gh attestation verify --help >/dev/null 2>&1; then
        info "GitHub CLI attestation verification is available for release provenance checks."
    fi
    if command -v shellcheck >/dev/null 2>&1; then ok "shellcheck is available"; else info "shellcheck is optional at runtime."; fi

    if (( issues == 0 )); then
        ok "Local trust health is clean."
        return 0
    fi
    warn "$issues local security issue(s) need attention."
    return 1
}
