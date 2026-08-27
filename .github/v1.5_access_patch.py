from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected target once, got {count}")
    p.write_text(s.replace(old, new))


replace_once(
    "src/access.sh",
    '''ensure_managed_key() {
    if [[ -f "$MANAGED_KEY.pub" && -f "$MANAGED_KEY" ]]; then
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
''',
    '''key_path_is_safe() {
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
''',
)

replace_once(
    "src/access.sh",
    '''key_generate() {
    local path="${1:-$MANAGED_KEY}" comment="${2:-skm@$(hostname 2>/dev/null || printf local)}"
    [[ "$path" == "$SSH_DIR/"* ]] || { fail "Key must be created inside $SSH_DIR."; return 1; }
    [[ ! -e "$path" && ! -e "$path.pub" ]] || { fail "Key already exists: $path"; return 1; }
    mkdir -p "$SSH_DIR" || { fail "Cannot create $SSH_DIR."; return 1; }
    chmod 700 "$SSH_DIR" 2>/dev/null || true
    ssh-keygen -t ed25519 -a 64 -f "$path" -C "$comment" || { fail "Key generation failed."; return 1; }
    chmod 600 "$path"; chmod 644 "$path.pub"
    ok "Created $path and $path.pub."
}
''',
    '''key_generate() {
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
''',
)

replace_once(
    "src/access.sh",
    '''doctor() {
    local issues=0 mode file line type
    say "$APP_NAME security check"
    if [[ -d "$SSH_DIR" ]]; then
        mode=$(file_mode "$SSH_DIR" 2>/dev/null || true)
        if [[ "$mode" == "700" ]]; then ok "$SSH_DIR permissions: 700"; else warn "$SSH_DIR permissions should be 700 (found ${mode:-unknown})."; issues=$((issues+1)); fi
    else warn "$SSH_DIR does not exist yet."; fi
    if [[ -f "$AUTHORIZED_KEYS" ]]; then
        if [[ -L "$AUTHORIZED_KEYS" ]]; then fail "$AUTHORIZED_KEYS is a symlink."; issues=$((issues+1)); fi
        mode=$(file_mode "$AUTHORIZED_KEYS" 2>/dev/null || true)
        if [[ "$mode" == "600" ]]; then ok "authorized_keys permissions: 600"; else warn "authorized_keys permissions should be 600 (found ${mode:-unknown})."; issues=$((issues+1)); fi
        while IFS= read -r line; do
            type=$(key_algorithm "$line")
            if [[ "$type" == "ssh-rsa" || "$type" == "ssh-dss" ]]; then warn "Legacy authorized key type: $type ($(key_fingerprint "$line"))"; issues=$((issues+1)); fi
        done < "$AUTHORIZED_KEYS"
    fi
    if [[ "$STRICT_HOST_KEY_CHECKING" == "yes" ]]; then ok "Strict host key checking: yes"; else warn "Strict host key checking is '$STRICT_HOST_KEY_CHECKING'. Use 'yes' for pre-provisioned known_hosts."; fi
    if command -v shellcheck >/dev/null 2>&1; then ok "shellcheck is available"; else info "shellcheck is optional at runtime."; fi
    if (( issues == 0 )); then ok "No local key-permission issues found."; else warn "$issues issue(s) need attention."; fi
    return "$issues"
}
''',
    '''doctor_file_mode() {
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
''',
)

p = Path("tests/access_test.sh")
s = p.read_text()
target = '''assert_eq "644" "$(file_mode "$key_path")" "managed public key mode is 644"
'''
addition = target + '''managed_original="$SKM_MANAGED_KEY"
ln -s "$managed_original" "$SKM_SSH_DIR/id_symlinked_skm"
ln -s "$managed_original.pub" "$SKM_SSH_DIR/id_symlinked_skm.pub"
SKM_MANAGED_KEY="$SKM_SSH_DIR/id_symlinked_skm"
MANAGED_KEY="$SKM_MANAGED_KEY"
assert_false "managed key symlinks are refused" ensure_managed_key >/dev/null 2>&1
SKM_MANAGED_KEY="$managed_original"
MANAGED_KEY="$managed_original"
rm -f "$SKM_SSH_DIR/id_symlinked_skm" "$SKM_SSH_DIR/id_symlinked_skm.pub"
assert_false "key generation rejects path traversal" key_generate "$SKM_SSH_DIR/../escaped-key" safe >/dev/null 2>&1
assert_false "key generation rejects nested key paths" key_generate "$SKM_SSH_DIR/nested/key" safe >/dev/null 2>&1
assert_false "key generation rejects unsafe control characters in comments" key_generate "$SKM_SSH_DIR/control-comment" $'bad\\ecomment' >/dev/null 2>&1
'''
if s.count(target) != 1:
    raise SystemExit("tests/access_test.sh: managed key assertion target missing")
p.write_text(s.replace(target, addition))
