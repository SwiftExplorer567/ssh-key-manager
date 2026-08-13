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

is_local_host() {
    local address="${HOST_ADDRS[$1]}"
    [[ "$address" == "local" || "$address" == "localhost" || "$address" == "127.0.0.1" || "$address" == "::1" ]]
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
    HOST_NAMES+=("$name"); HOST_USERS+=("$user"); HOST_ADDRS+=("$host"); HOST_PORTS+=("$port")
    save_hosts || { fail "Could not save machine."; return 1; }
    ok "Saved $name ($user@$host:$port)."
}

host_remove() {
    local name="$1" index
    require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX
    unset 'HOST_NAMES[index]' 'HOST_USERS[index]' 'HOST_ADDRS[index]' 'HOST_PORTS[index]'
    HOST_NAMES=("${HOST_NAMES[@]}"); HOST_USERS=("${HOST_USERS[@]}")
    HOST_ADDRS=("${HOST_ADDRS[@]}"); HOST_PORTS=("${HOST_PORTS[@]}")
    save_hosts || { fail "Could not save machine list."; return 1; }
    ok "Removed $name. SSH keys were not changed."
}

host_test() {
    local index; require_host "$1" || return 1; index=$RESOLVED_HOST_INDEX
    if is_local_host "$index" || ssh_run_batch "$index" true >/dev/null 2>&1; then
        ok "Passwordless access to ${HOST_NAMES[$index]} is ready."
    else
        fail "No passwordless access to ${HOST_NAMES[$index]}. Run: skm access grant ${HOST_NAMES[$index]}"
        return 1
    fi
}
