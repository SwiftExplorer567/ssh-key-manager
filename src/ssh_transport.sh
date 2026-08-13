# shellcheck shell=bash

ssh_run() {
    local index="$1"; shift
    local target; target=$(ssh_target "$index")
    local args=(-o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -p "${HOST_PORTS[$index]}")
    [[ -f "$MANAGED_KEY" ]] && args+=(-i "$MANAGED_KEY")
    # Callers pass fixed, application-owned remote scripts only.
    # shellcheck disable=SC2029
    ssh "${args[@]}" "$target" "$@"
}

ssh_run_batch() {
    local index="$1"; shift
    local target; target=$(ssh_target "$index")
    local args=(-o BatchMode=yes -o PasswordAuthentication=no -o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING" -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -p "${HOST_PORTS[$index]}")
    [[ -f "$MANAGED_KEY" ]] && args+=(-i "$MANAGED_KEY")
    # Callers pass fixed, application-owned remote scripts only.
    # shellcheck disable=SC2029
    ssh "${args[@]}" "$target" "$@"
}

connect_host() {
    local name="$1" index; require_host "$name" || return 1; index=$RESOLVED_HOST_INDEX; shift
    if is_local_host "$index"; then fail "'$name' points to this machine; no SSH connection is needed."; return 1; fi
    local target; target=$(ssh_target "$index")
    local args=(-o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING" -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -p "${HOST_PORTS[$index]}")
    [[ -f "$MANAGED_KEY" ]] && args+=(-i "$MANAGED_KEY")
    # Remaining arguments are an explicitly user-supplied SSH command/options tail.
    # shellcheck disable=SC2029
    ssh "${args[@]}" "$target" "$@"
}
