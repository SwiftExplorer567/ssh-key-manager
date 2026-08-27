# shellcheck shell=bash

ssh_run() {
    local index="$1"; shift
    local target; target=$(ssh_target "$index")
    local args=(-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -p "${HOST_PORTS[$index]}")
    if host_has_pin "$index"; then
        args+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o GlobalKnownHostsFile=/dev/null)
    else
        args+=(-o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING")
    fi
    if [[ -f "$MANAGED_KEY" ]]; then
        args+=(-i "$MANAGED_KEY" -o IdentitiesOnly=yes)
    fi
    # Callers pass fixed, application-owned remote scripts only.
    # shellcheck disable=SC2029
    ssh "${args[@]}" "$target" "$@"
}

ssh_run_batch() {
    local index="$1"; shift
    local target; target=$(ssh_target "$index")
    local args=(-o BatchMode=yes -o PasswordAuthentication=no -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -p "${HOST_PORTS[$index]}")
    if host_has_pin "$index"; then
        args+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS_FILE" -o GlobalKnownHostsFile=/dev/null)
    else
        args+=(-o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING")
    fi
    if [[ -f "$MANAGED_KEY" ]]; then
        args+=(-i "$MANAGED_KEY" -o IdentitiesOnly=yes)
    fi
    # Callers pass fixed, application-owned remote scripts only.
    # shellcheck disable=SC2029
    ssh "${args[@]}" "$target" "$@"
}
