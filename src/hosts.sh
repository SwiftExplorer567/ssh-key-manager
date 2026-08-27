# shellcheck shell=bash

load_hosts() {
    HOST_NAMES=() HOST_USERS=() HOST_ADDRS=() HOST_PORTS=()
    local name user host port
    while IFS='|' read -r name user host port _ || [[ -n "$name" ]]; do
        name="$(trim "$name")"
        [[ -z "$name" || "$name" == \#* ]] && continue
        user="$(trim "$user")"; host="$(trim "$host")"; port="$(trim "${port:-22}")"
        if [[ "$name" == *'|'* || "$user" == *'|'* || "$host" == *'|'* ]] ||
           ! valid_user "$user" || ! valid_host "$host" || ! valid_port "$port"; then
            warn "Skipped invalid host record: $name"
            continue
        fi
        HOST_NAMES+=("$name")
        HOST_USERS+=("$user")
        HOST_ADDRS+=("$host")
        HOST_PORTS+=("$port")
    done < "$HOSTS_FILE"
}

save_hosts() {
    local tmp i
    [[ ! -L "$HOSTS_FILE" ]] || { fail "Refusing to replace symlinked machine registry."; return 1; }
    tmp=$(mktemp "$CONFIG_DIR/servers.conf.XXXXXX") || return 1
    chmod 600 "$tmp" 2>/dev/null || true
    for i in "${!HOST_NAMES[@]}"; do
        printf '%s|%s|%s|%s\n' "${HOST_NAMES[$i]}" "${HOST_USERS[$i]}" "${HOST_ADDRS[$i]}" "${HOST_PORTS[$i]}" >> "$tmp"
    done
    mv -f "$tmp" "$HOSTS_FILE"
}

host_index() {
    local wanted="$1" i
    for i in "${!HOST_NAMES[@]}"; do
        if [[ "${HOST_NAMES[$i]}" == "$wanted" ]]; then printf '%s' "$i"; return 0; fi
    done
    return 1
}

require_host() {
    RESOLVED_HOST_INDEX=-1
    local wanted="$1" i
    for i in "${!HOST_NAMES[@]}"; do
        if [[ "${HOST_NAMES[$i]}" == "$wanted" ]]; then RESOLVED_HOST_INDEX=$i; return 0; fi
    done
    fail "Unknown machine '$wanted'. Run: skm host list"
    return 1
}

address_is_local() {
    local address="$1"
    [[ "$address" == "local" || "$address" == "localhost" || "$address" == "127.0.0.1" || "$address" == "::1" ]]
}

is_local_host() { address_is_local "${HOST_ADDRS[$1]}"; }

other_local_host_exists() {
    local excluded="${1:--1}" i
    for i in "${!HOST_NAMES[@]}"; do
        [[ "$i" == "$excluded" ]] && continue
        is_local_host "$i" && return 0
    done
    return 1
}

ssh_target() { printf '%s@%s' "${HOST_USERS[$1]}" "${HOST_ADDRS[$1]}"; }

host_list() {
    if (( ${#HOST_NAMES[@]} == 0 )); then
        say "No machines saved. Add one with: skm host add NAME USER HOST [PORT]"
        return 0
    fi
    printf '%-18s %-18s %-30s %s\n' NAME USER HOST PORT
    local i
    for i in "${!HOST_NAMES[@]}"; do
        printf '%-18s %-18s %-30s %s\n' "${HOST_NAMES[$i]}" "${HOST_USERS[$i]}" "${HOST_ADDRS[$i]}" "${HOST_PORTS[$i]}"
    done
}

host_show() {
    local index
    require_host "$1" || return 1
    index=$RESOLVED_HOST_INDEX
    printf 'Name: %s\n' "${HOST_NAMES[$index]}"
    printf 'User: %s\n' "${HOST_USERS[$index]}"
    printf 'Host: %s\n' "${HOST_ADDRS[$index]}"
    printf 'Port: %s\n' "${HOST_PORTS[$index]}"
    if is_local_host "$index"; then printf 'Local: yes\n'; else printf 'Local: no\n'; fi
}

host_add() {
    local name="${1:-}" user="${2:-}" host="${3:-}" port="${4:-22}"
    [[ -n "$name" ]] || name=$(prompt "Short machine name (example: storage)")
    [[ -n "$user" ]] || user=$(prompt "SSH user" "$USER")
    [[ -n "$host" ]] || host=$(prompt "Hostname or IP")
    [[ -n "$port" ]] || port=22
    valid_name "$name" || { fail "Name must use letters, numbers, dot, dash, or underscore (max 63)."; return 1; }
    valid_user "$user" || { fail "Invalid SSH user."; return 1; }
    valid_host "$host" || { fail "Invalid hostname or IP."; return 1; }
    valid_port "$port" || { fail "Port must be between 1 and 65535."; return 1; }
    if host_index "$name" >/dev/null 2>&1; then fail "Machine '$name' already exists."; return 1; fi
    if address_is_local "$host" && other_local_host_exists; then
        fail "Only one saved machine may represent this local SKM node."
        return 1
    fi
    HOST_NAMES+=("$name"); HOST_USERS+=("$user"); HOST_ADDRS+=("$host"); HOST_PORTS+=("$port")
    save_hosts || { fail "Could not save machine."; return 1; }
    ok "Saved $name ($user@$host:$port)."
}

host_policy_reference_count() {
    local name="$1" i count=0
    load_policy
    for i in "${!POLICY_HOSTS[@]}"; do
        [[ "${POLICY_HOSTS[$i]}" == "$name" ]] && count=$((count + 1))
    done
    printf '%s' "$count"
}

host_rename() {
    local old_name="$1" new_name="$2" index i
    local -a old_policy_hosts
    valid_name "$new_name" || { fail "Invalid new machine name."; return 1; }
    require_host "$old_name" || return 1
    index=$RESOLVED_HOST_INDEX
    if host_index "$new_name" >/dev/null 2>&1; then fail "Machine '$new_name' already exists."; return 1; fi
    load_policy
    old_policy_hosts=("${POLICY_HOSTS[@]}")
    HOST_NAMES[index]="$new_name"
    for i in "${!POLICY_HOSTS[@]}"; do
        [[ "${POLICY_HOSTS[$i]}" == "$old_name" ]] && POLICY_HOSTS[i]="$new_name"
    done
    if ! save_hosts || ! save_policy; then
        HOST_NAMES[index]="$old_name"
        POLICY_HOSTS=("${old_policy_hosts[@]}")
        save_hosts >/dev/null 2>&1 || true
        save_policy >/dev/null 2>&1 || true
        fail "Could not rename machine safely; previous configuration was restored."
        return 1
    fi
    ok "Renamed machine $old_name to $new_name; policy references were migrated."
}

host_edit() {
    local name="$1" user="$2" host="$3" port="${4:-22}" index
    require_host "$name" || return 1
    index=$RESOLVED_HOST_INDEX
    valid_user "$user" || { fail "Invalid SSH user."; return 1; }
    valid_host "$host" || { fail "Invalid hostname or IP."; return 1; }
    valid_port "$port" || { fail "Port must be between 1 and 65535."; return 1; }
    if address_is_local "$host" && other_local_host_exists "$index"; then
        fail "Only one saved machine may represent this local SKM node."
        return 1
    fi
    HOST_USERS[index]="$user"
    HOST_ADDRS[index]="$host"
    HOST_PORTS[index]="$port"
    save_hosts || { fail "Could not update machine."; return 1; }
    ok "Updated $name ($user@$host:$port)."
}

host_remove() {
    local name="$1" force="${2:-}" index refs i
    local -a old_names old_users old_addrs old_ports old_policy_fps old_policy_hosts
    require_host "$name" || return 1
    index=$RESOLVED_HOST_INDEX
    refs=$(host_policy_reference_count "$name")
    if (( refs > 0 )) && [[ "$force" != "--force" ]]; then
        fail "Machine '$name' is referenced by $refs desired-state policy rule(s). Use --force to remove the machine and those policy rules."
        return 1
    fi

    old_names=("${HOST_NAMES[@]}"); old_users=("${HOST_USERS[@]}")
    old_addrs=("${HOST_ADDRS[@]}"); old_ports=("${HOST_PORTS[@]}")
    old_policy_fps=("${POLICY_FINGERPRINTS[@]}"); old_policy_hosts=("${POLICY_HOSTS[@]}")

    unset 'HOST_NAMES[index]' 'HOST_USERS[index]' 'HOST_ADDRS[index]' 'HOST_PORTS[index]'
    HOST_NAMES=("${HOST_NAMES[@]}"); HOST_USERS=("${HOST_USERS[@]}")
    HOST_ADDRS=("${HOST_ADDRS[@]}"); HOST_PORTS=("${HOST_PORTS[@]}")

    if (( refs > 0 )); then
        local -a kept_fps kept_hosts
        local kept_count=0
        kept_fps=() kept_hosts=()
        for i in "${!POLICY_HOSTS[@]}"; do
            [[ "${POLICY_HOSTS[$i]}" == "$name" ]] && continue
            kept_fps+=("${POLICY_FINGERPRINTS[$i]}")
            kept_hosts+=("${POLICY_HOSTS[$i]}")
            kept_count=$((kept_count + 1))
        done
        POLICY_FINGERPRINTS=()
        POLICY_HOSTS=()
        if (( kept_count > 0 )); then
            POLICY_FINGERPRINTS=("${kept_fps[@]}")
            POLICY_HOSTS=("${kept_hosts[@]}")
        fi
    fi

    if ! save_hosts || ! save_policy; then
        HOST_NAMES=("${old_names[@]}"); HOST_USERS=("${old_users[@]}")
        HOST_ADDRS=("${old_addrs[@]}"); HOST_PORTS=("${old_ports[@]}")
        POLICY_FINGERPRINTS=("${old_policy_fps[@]}"); POLICY_HOSTS=("${old_policy_hosts[@]}")
        save_hosts >/dev/null 2>&1 || true
        save_policy >/dev/null 2>&1 || true
        fail "Could not remove machine safely; previous configuration was restored."
        return 1
    fi
    if (( refs > 0 )); then
        ok "Removed $name and $refs policy rule(s). SSH keys were not changed."
    else
        ok "Removed $name. SSH keys were not changed."
    fi
}

host_test() {
    local index; require_host "$1" || return 1; index=$RESOLVED_HOST_INDEX
    if is_local_host "$index" || ssh_run_batch "$index" true >/dev/null 2>&1; then
        ok "${HOST_NAMES[$index]} is reachable for key management."
    else
        fail "${HOST_NAMES[$index]} is not reachable with the current management key. Run: skm access grant ${HOST_NAMES[$index]}"
        return 1
    fi
}
