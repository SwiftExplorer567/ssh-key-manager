# shellcheck shell=bash

host_known_hosts_token_values() {
    local host="$1" port="$2"
    if [[ "$port" == "22" ]]; then printf '%s' "$host"; else printf '[%s]:%s' "$host" "$port"; fi
}

host_known_hosts_token() {
    local index="$1"
    host_known_hosts_token_values "${HOST_ADDRS[$index]}" "${HOST_PORTS[$index]}"
}

host_has_pin() {
    local index="$1" token
    [[ -s "$KNOWN_HOSTS_FILE" ]] || return 1
    token=$(host_known_hosts_token "$index")
    ssh-keygen -F "$token" -f "$KNOWN_HOSTS_FILE" >/dev/null 2>&1
}

host_scan_keys() {
    local index="$1" host="${HOST_ADDRS[$1]}" port="${HOST_PORTS[$1]}"
    command -v ssh-keyscan >/dev/null 2>&1 || { fail "ssh-keyscan is required for host trust commands."; return 1; }
    is_local_host "$index" && { fail "Local machine host keys are not pinned through SKM."; return 1; }
    ssh-keyscan -T 5 -p "$port" "$host" 2>/dev/null | awk 'NF >= 3 && $2 ~ /^(ssh-|ecdsa-|sk-)/ { print $1, $2, $3 }'
}

host_key_fingerprint_line() {
    local line="$1" key
    key=$(awk '{print $2, $3}' <<< "$line")
    printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}'
}

host_fingerprint() {
    local index scan line fingerprint algorithm found=0
    require_host "$1" || return 1
    index=$RESOLVED_HOST_INDEX
    scan=$(host_scan_keys "$index") || return 1
    [[ -n "$scan" ]] || { fail "No SSH host keys were returned by ${HOST_NAMES[$index]}."; return 1; }
    printf '%-26s %s\n' FINGERPRINT ALGORITHM
    while IFS= read -r line || [[ -n "$line" ]]; do
        fingerprint=$(host_key_fingerprint_line "$line")
        algorithm=$(awk '{print $2}' <<< "$line")
        [[ -n "$fingerprint" ]] || continue
        found=1
        printf '%-26s %s\n' "$fingerprint" "$algorithm"
    done <<< "$scan"
    (( found == 1 ))
}

host_trust() {
    local name="$1" expected="${2:-}" index scan line fingerprint selected="" token tmp
    require_host "$name" || return 1
    index=$RESOLVED_HOST_INDEX
    scan=$(host_scan_keys "$index") || return 1
    [[ -n "$scan" ]] || { fail "No SSH host keys were returned by $name."; return 1; }

    if [[ -n "$expected" ]]; then
        [[ "$expected" =~ ^SHA256:[A-Za-z0-9+/=_-]+$ ]] || { fail "Expected host fingerprint must be SHA256:..."; return 1; }
        while IFS= read -r line || [[ -n "$line" ]]; do
            fingerprint=$(host_key_fingerprint_line "$line")
            if [[ "$fingerprint" == "$expected" ]]; then selected="$line"; break; fi
        done <<< "$scan"
        [[ -n "$selected" ]] || { fail "Scanned host keys did not match expected fingerprint $expected."; return 1; }
    else
        say "Host keys currently presented by $name:"
        host_fingerprint "$name" || return 1
        confirm "Pin these host keys for $name?" n || { fail "Host trust was not changed."; return 1; }
        selected="$scan"
    fi

    [[ ! -L "$KNOWN_HOSTS_FILE" ]] || { fail "Refusing to replace symlinked SKM known_hosts file."; return 1; }
    token=$(host_known_hosts_token "$index")
    tmp=$(mktemp "$CONFIG_DIR/known_hosts.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$KNOWN_HOSTS_FILE" ]]; then
        awk -v wanted="$token" '$1 != wanted { print }' "$KNOWN_HOSTS_FILE" > "$tmp"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        printf '%s %s %s\n' "$token" "$(awk '{print $2}' <<< "$line")" "$(awk '{print $3}' <<< "$line")" >> "$tmp"
    done <<< "$selected"
    mv -f "$tmp" "$KNOWN_HOSTS_FILE"
    chmod 600 "$KNOWN_HOSTS_FILE" 2>/dev/null || true
    ok "Pinned SSH host trust for $name ($token)."
}

host_untrust() {
    local index token tmp
    require_host "$1" || return 1
    index=$RESOLVED_HOST_INDEX
    token=$(host_known_hosts_token "$index")
    [[ ! -L "$KNOWN_HOSTS_FILE" ]] || { fail "Refusing to replace symlinked SKM known_hosts file."; return 1; }
    tmp=$(mktemp "$CONFIG_DIR/known_hosts.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    if [[ -f "$KNOWN_HOSTS_FILE" ]]; then awk -v wanted="$token" '$1 != wanted { print }' "$KNOWN_HOSTS_FILE" > "$tmp"; fi
    mv -f "$tmp" "$KNOWN_HOSTS_FILE"
    chmod 600 "$KNOWN_HOSTS_FILE" 2>/dev/null || true
    ok "Removed SKM host-key pin for $1."
}

host_verify() {
    local index token scan pinned line fp scan_fps="" matched=0
    require_host "$1" || return 1
    index=$RESOLVED_HOST_INDEX
    host_has_pin "$index" || { fail "No SKM host-key pin exists for $1. Run: skm host trust $1"; return 1; }
    token=$(host_known_hosts_token "$index")
    scan=$(host_scan_keys "$index") || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        fp=$(host_key_fingerprint_line "$line")
        [[ -n "$fp" ]] && scan_fps="${scan_fps}${scan_fps:+$'\n'}$fp"
    done <<< "$scan"
    pinned=$(awk -v wanted="$token" '$1 == wanted { print }' "$KNOWN_HOSTS_FILE")
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        fp=$(host_key_fingerprint_line "$line")
        if [[ -n "$fp" ]] && grep -Fqx "$fp" <<< "$scan_fps"; then matched=1; break; fi
    done <<< "$pinned"
    if (( matched == 1 )); then
        ok "Pinned SSH host key for $1 is still presented by the server."
        return 0
    fi
    fail "SSH host key verification failed for $1; the pinned key is no longer presented."
    return 1
}
