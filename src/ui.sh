# shellcheck shell=bash

terminal_width() {
    local width
    width=$(tput cols 2>/dev/null || printf '80')
    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    (( width < 52 )) && width=52
    (( width > 100 )) && width=100
    printf '%s' "$width"
}

clear_screen() {
    if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then printf '\033[2J\033[H'; else printf '\n'; fi
}

ui_rule() {
    local width="${1:-$(terminal_width)}" i
    printf '  %s' "$C_MUTED"
    for ((i=0; i<width-4; i++)); do printf '─'; done
    printf '%s\n' "$C_RESET"
}

ui_header() {
    local section="${1:-Dashboard}" width hosts plural="s" update_text=""
    width=$(terminal_width); hosts=${#HOST_NAMES[@]}
    (( hosts == 1 )) && plural=""
    if (( UPDATE_AVAILABLE == 1 )); then update_text="  ${C_YELLOW}● v${LATEST_VERSION} available${C_RESET}"; fi
    clear_screen
    printf '\n  %s◆%s  %s%s%s  %sv%s%s%b\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$APP_NAME" "$C_RESET" "$C_MUTED" "$VERSION" "$C_RESET" "$update_text"
    printf '  %sKEY MANAGEMENT%s  %s/%s  %s%s%s  %s· %d machine%s%s\n' "$C_DIM" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_SILVER" "$section" "$C_RESET" "$C_MUTED" "$hosts" "$plural" "$C_RESET"
    ui_rule "$width"
}

ui_notice() {
    local tone="$1" title="$2" body="$3" color="$C_ACCENT" icon="●"
    case "$tone" in success) color="$C_GREEN"; icon="✓";; warning) color="$C_YELLOW"; icon="!";; danger) color="$C_RED"; icon="×";; esac
    printf '\n  %s%s  %s%s%s\n  %s   %s%s\n' "$color" "$icon" "$C_BOLD" "$title" "$C_RESET" "$C_MUTED" "$body" "$C_RESET"
}

ui_step() {
    printf '  %sSTEP %s%s  %s%s%s\n' "$C_ACCENT" "$1" "$C_RESET" "$C_MUTED" "$2" "$C_RESET"
}

render_menu() {
    local title="$1" subtitle="$2" selected="$3"; shift 3
    local options=("$@") i label description marker width max_desc
    width=$(terminal_width)
    max_desc=$((width - 12)); (( max_desc < 20 )) && max_desc=20
    ui_header "$title"
    [[ -n "$subtitle" ]] && printf '\n  %s%s%s\n' "$C_MUTED" "$subtitle" "$C_RESET"
    printf '\n'
    for i in "${!options[@]}"; do
        label="${options[$i]%%|*}"
        description="${options[$i]#*|}"
        [[ "$description" == "$label" ]] && description=""
        if (( ${#description} > max_desc )); then description="${description:0:max_desc-1}…"; fi
        if (( i == selected )); then
            marker="${C_ACCENT}❯${C_RESET}"
            printf '  %b  %s%2d%s  %s%s%s\n' "$marker" "$C_ACCENT" "$((i + 1))" "$C_RESET" "$C_BOLD$C_ACCENT" "$label" "$C_RESET"
            [[ -n "$description" ]] && printf '         %s%s%s\n' "$C_SILVER" "$description" "$C_RESET"
        else
            printf '     %s%2d%s  %s%s%s\n' "$C_DIM" "$((i + 1))" "$C_RESET" "$C_SILVER" "$label" "$C_RESET"
            [[ -n "$description" ]] && printf '         %s%s%s\n' "$C_MUTED" "$description" "$C_RESET"
        fi
        (( i < ${#options[@]} - 1 )) && printf '\n'
    done
    printf '\n  %s↑↓/jk navigate  ·  Enter select  ·  q back%s\n' "$C_DIM" "$C_RESET"
}

run_menu() {
    local title="$1" subtitle="$2"; shift 2
    local options=("$@") selected=0 max key tail number
    MENU_RESULT=-1
    max=$((${#options[@]} - 1))
    (( max >= 0 )) || return 1

    if [[ ! -t 0 && "${SKM_FORCE_TUI:-0}" != "1" ]]; then
        render_menu "$title" "$subtitle" "$selected" "${options[@]}"
        return 1
    fi

    hide_cursor
    while true; do
        render_menu "$title" "$subtitle" "$selected" "${options[@]}"
        IFS= read -rsn1 key || { show_cursor; return 1; }
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 1 tail || tail=""
                case "$tail" in
                    '[A') selected=$((selected == 0 ? max : selected - 1));;
                    '[B') selected=$((selected == max ? 0 : selected + 1));;
                esac
                ;;
            k|K) selected=$((selected == 0 ? max : selected - 1));;
            j|J) selected=$((selected == max ? 0 : selected + 1));;
            q|Q) show_cursor; MENU_RESULT=-1; return 0;;
            '') show_cursor; MENU_RESULT=$selected; return 0;;
            [1-9])
                number=$((10#$key - 1))
                if (( number <= max )); then show_cursor; MENU_RESULT=$number; return 0; fi
                ;;
        esac
    done
}

ui_pause() {
    if [[ -t 0 ]]; then show_cursor; printf '\n  %sPress Enter to continue…%s' "$C_MUTED" "$C_RESET"; IFS= read -r _ || true; fi
}


refresh_host_statuses() {
    HOST_STATUSES=()
    local tmp_dir i
    tmp_dir=$(mktemp -d "$CONFIG_DIR/status.XXXXXX") || return 1
    for i in "${!HOST_NAMES[@]}"; do
        if is_local_host "$i"; then
            printf 'local\n' > "$tmp_dir/$i"
        else
            (if ssh_run_batch "$i" true >/dev/null 2>&1; then printf 'ready\n'; else printf 'offline\n'; fi) > "$tmp_dir/$i" &
        fi
    done
    wait 2>/dev/null || true
    for i in "${!HOST_NAMES[@]}"; do
        if [[ -f "$tmp_dir/$i" ]]; then
            IFS= read -r "HOST_STATUSES[$i]" < "$tmp_dir/$i"
        else
            HOST_STATUSES[i]="unknown"
        fi
    done
    rm -rf "$tmp_dir"
}

host_status_text() {
    case "${HOST_STATUSES[$1]:-unknown}" in
        ready) printf '● ready';;
        local) printf '● this machine';;
        offline) printf '● unavailable';;
        *) printf '● unchecked';;
    esac
}

select_host() {
    local title="${1:-Choose a machine}" remote_only="${2:-false}" i status
    local options=() indices=()
    SELECTED_HOST=""; SELECTED_HOST_INDEX=-1
    for i in "${!HOST_NAMES[@]}"; do
        if [[ "$remote_only" == "true" ]] && is_local_host "$i"; then continue; fi
        status=$(host_status_text "$i")
        options+=("${HOST_NAMES[$i]}|${HOST_USERS[$i]}@${HOST_ADDRS[$i]}:${HOST_PORTS[$i]}  ·  $status")
        indices+=("$i")
    done
    if (( ${#options[@]} == 0 )); then
        ui_header "$title"
        if [[ "$remote_only" == "true" ]]; then
            ui_notice warning "No remote machines" "Add one from Machines first."
        else
            ui_notice warning "No machines" "Add one from Machines first."
        fi
        ui_pause; return 1
    fi
    run_menu "$title" "Choose by name; no key files are shown here." "${options[@]}"
    (( MENU_RESULT >= 0 )) || return 1
    SELECTED_HOST_INDEX=${indices[$MENU_RESULT]}
    SELECTED_HOST="${HOST_NAMES[$SELECTED_HOST_INDEX]}"
}

interactive_grant_other_device() {
    local public_key options target i rc=0 remote_count=0 total_count
    ui_header "Give Access"
    ui_step "1 OF 3" "Get the public key from the device"
    printf '\n  On the client device run:  %sskm key public%s\n' "$C_BOLD" "$C_RESET"
    printf '  %sIf it has no key, SKM creates one there. The private key stays on that device.%s\n\n' "$C_MUTED" "$C_RESET"
    public_key=$(prompt "  Paste its public key") || return
    if ! valid_public_key "$public_key"; then
        ui_notice danger "That is not a valid public key" "Paste the complete line beginning with ssh-ed25519 or another supported type."
        ui_pause; return
    fi
    for i in "${!HOST_NAMES[@]}"; do is_local_host "$i" || remote_count=$((remote_count + 1)); done
    total_count=$((remote_count + 1))
    options=(
        "This machine|Allow the client on the device running SKM"
        "One remote machine|Choose one saved server or device"
        "All machines|Authorize the client here and on all $remote_count saved remote machines"
        "Cancel|Make no changes"
    )
    run_menu "Give Access" "Step 2 of 3 · choose the destination." "${options[@]}"
    case "$MENU_RESULT" in
        0)
            ui_header "Review Access"
            ui_step "3 OF 3" "Confirm the grant"
            ui_notice warning "CLIENT DEVICE  →  THIS MACHINE" "Only the pasted public key will be added."
            confirm "Give this client access to this machine?" y && access_allow_public_key "$public_key"
            ;;
        1)
            select_host "Choose Destination" true || return
            target="$SELECTED_HOST"
            ui_header "Review Access"
            ui_step "3 OF 3" "Confirm the grant"
            ui_notice warning "CLIENT DEVICE  →  $target" "Only the pasted public key will be added."
            confirm "Give this client access to $target?" y && access_grant_public_key "$target" "$public_key"
            ;;
        2)
            ui_header "Review Access"
            ui_step "3 OF 3" "Confirm the grant"
            ui_notice warning "CLIENT DEVICE  →  ALL $total_count MACHINES" "The same public key will be authorized here and on every saved remote machine."
            if confirm "Give this client access to all managed machines?" n; then
                access_allow_public_key "$public_key" || rc=1
                for i in "${!HOST_NAMES[@]}"; do
                    is_local_host "$i" && continue
                    access_grant_public_key "${HOST_NAMES[$i]}" "$public_key" || rc=1
                done
                if (( rc == 0 )); then
                    ui_notice success "Access granted" "The client key is authorized on all managed machines."
                else
                    ui_notice warning "Partially completed" "Review the messages above; at least one machine could not be updated."
                fi
            fi
            ;;
        *) return;;
    esac
    ui_pause
}

interactive_access_setup() {
    local preselected="${1:-}" name options
    if [[ -n "$preselected" ]]; then
        require_host "$preselected" || return; SELECTED_HOST="$preselected"; SELECTED_HOST_INDEX=$RESOLVED_HOST_INDEX
        name="$SELECTED_HOST"
        ui_header "Review Access"
        ui_notice warning "THIS DEVICE  →  $name" "SKM will create this device's key if needed, then add only its public key."
        confirm "Give this device access to $name?" y && access_grant "$name"
        ui_pause; refresh_host_statuses || true
        return
    fi
    options=(
        "This device|Create or reuse this device's key, then choose one machine"
        "Another device|Paste a client public key and allow it on one or all machines"
        "Cancel|Return to dashboard"
    )
    run_menu "Give Access" "Who needs access? You will review the destination before anything changes." "${options[@]}"
    case "$MENU_RESULT" in
        0)
            select_host "Choose Destination" true || return; name="$SELECTED_HOST"
            ui_header "Review Access"; ui_notice warning "THIS DEVICE  →  $name" "Only this device's public key will be added."
            confirm "Give this device access to $name?" y && access_grant "$name"; ui_pause
            ;;
        1) interactive_grant_other_device;;
        *) return;;
    esac
    refresh_host_statuses || true
}

interactive_access_map() {
    ui_header "Access Overview"
    printf '\n  %sArrows show which machine identity is authorized on which destination.%s\n' "$C_MUTED" "$C_RESET"
    access_status || true
    ui_pause
}

interactive_add_host() {
    local name user host port
    ui_header "Add Machine"
    printf '\n  Add a server, Raspberry Pi, NAS, or workstation whose keys you want to manage.\n\n'
    ui_step "1 OF 3" "Name it"
    name=$(prompt "  Friendly name (example: rpi5)") || return
    ui_step "2 OF 3" "SSH login"
    user=$(prompt "  Username" "$USER") || return
    ui_step "3 OF 3" "Network address"
    host=$(prompt "  Hostname or IP (example: 192.168.1.20)") || return
    port=$(prompt "  SSH port" "22") || return
    if ! valid_name "$name" || ! valid_user "$user" || ! valid_host "$host" || ! valid_port "$port"; then
        ui_notice danger "Invalid machine details" "Names cannot contain spaces; check user, host, and port."; ui_pause; return
    fi
    if host_index "$name" >/dev/null 2>&1; then ui_notice danger "Name already exists" "Choose another short name."; ui_pause; return; fi
    host_add "$name" "$user" "$host" "$port" || { ui_pause; return; }
    load_hosts; refresh_host_statuses || true
    if ! is_local_host "$(host_index "$name")" && confirm "Give this device access to $name now?" y; then interactive_access_setup "$name"; else ui_pause; fi
}

interactive_hosts() {
    local options name
    while true; do
        options=(
            "Add a machine|Register a server, Raspberry Pi, NAS, or workstation"
            "View machines|See saved details and key-management reachability"
            "Refresh status|Check which machines SKM can currently manage"
            "Remove a machine|Forget its record without deleting any SSH keys"
            "Back|Return to dashboard"
        )
        run_menu "Machines" "${#HOST_NAMES[@]} saved · adding a machine never copies a private key." "${options[@]}"
        case "$MENU_RESULT" in
            0) interactive_add_host;;
            1)
                select_host "Machine Details" false || continue
                ui_header "${SELECTED_HOST}"
                printf '\n  %sUser%s     %s\n  %sAddress%s  %s\n  %sPort%s     %s\n  %sStatus%s   %b\n' \
                    "$C_MUTED" "$C_RESET" "${HOST_USERS[$SELECTED_HOST_INDEX]}" "$C_MUTED" "$C_RESET" "${HOST_ADDRS[$SELECTED_HOST_INDEX]}" \
                    "$C_MUTED" "$C_RESET" "${HOST_PORTS[$SELECTED_HOST_INDEX]}" "$C_MUTED" "$C_RESET" "$(host_status_text "$SELECTED_HOST_INDEX")"
                printf '\n'; host_test "$SELECTED_HOST" || true; ui_pause
                ;;
            2)
                ui_header "Refreshing"; refresh_host_statuses; ui_notice success "Status refreshed" "Public-key management checks completed."; ui_pause
                ;;
            3)
                select_host "Remove Machine" false || continue; name="$SELECTED_HOST"
                ui_header "Remove Machine"; ui_notice danger "$name" "Only its SKM record is removed; SSH keys remain unchanged."
                if confirm "Remove $name?" n; then host_remove "$name" && load_hosts && refresh_host_statuses; fi; ui_pause
                ;;
            *) return;;
        esac
    done
}

interactive_security() {
    local options public_path
    while true; do
        options=(
            "Key inventory|See public identities and allowed keys on every reachable machine"
            "This device's public key|Create it if needed and show the safe-to-share line"
            "Revoke access|Choose a machine, then remove one authorized public key"
            "Security check|Audit local permissions, symlinks, and legacy algorithms"
            "Back|Return to dashboard"
        )
        run_menu "Keys & Security" "Fleet-wide public key visibility. Private keys are never read or transferred." "${options[@]}"
        case "$MENU_RESULT" in
            0) ui_header "Key Inventory"; key_list || true; ui_pause;;
            1)
                ui_header "This Device's Public Key"
                public_path=$(ensure_managed_key) || { ui_pause; continue; }
                ui_notice success "Safe to share" "Paste this public key into another key manager; keep the private file on this device."
                printf '\n  '; read_public_key_file "$public_path" || true; printf '\n'; ui_pause
                ;;
            2) select_host "Revoke Access On" false && access_revoke_remote "$SELECTED_HOST"; ui_pause;;
            3) ui_header "Security Check"; doctor || true; ui_pause;;
            *) return;;
        esac
    done
}

interactive_updates() {
    local state options
    while true; do
        if (( UPDATE_AVAILABLE == 1 )); then state="v$LATEST_VERSION is ready"; else state="v$VERSION is current"; fi
        options=(
            "Check now|Query the latest GitHub release tag"
            "Install update|Validate, back up, and atomically replace SKM"
            "Automatic checks: $AUTO_UPDATE_CHECK|Check at most once every 24 hours"
            "Back|Return to dashboard"
        )
        run_menu "Updates" "$state · updates are never installed without confirmation." "${options[@]}"
        case "$MENU_RESULT" in
            0)
                ui_header "Checking for Updates"
                if check_for_updates true; then
                    if (( UPDATE_AVAILABLE == 1 )); then
                        ui_notice warning "Update available" "v$VERSION → v$LATEST_VERSION"
                    else
                        ui_notice success "Up to date" "You are on v$VERSION."
                    fi
                else
                    ui_notice danger "Check failed" "GitHub could not be reached."
                fi
                ui_pause
                ;;
            1)
                ui_header "Install Update"
                if (( UPDATE_AVAILABLE == 0 )); then check_for_updates true || true; fi
                if (( UPDATE_AVAILABLE == 1 )); then
                    ui_notice warning "v$LATEST_VERSION" "The current executable will be backed up first."
                    if confirm "Install update now?" n; then install_latest_update; fi
                else
                    ui_notice success "Up to date" "No newer release is available."
                fi
                ui_pause
                ;;
            2)
                if [[ "$AUTO_UPDATE_CHECK" == "true" ]]; then AUTO_UPDATE_CHECK=false; else AUTO_UPDATE_CHECK=true; fi
                save_boolean_setting AUTO_UPDATE_CHECK "$AUTO_UPDATE_CHECK"
                ui_header "Updates"
                ui_notice success "Automatic checks: $AUTO_UPDATE_CHECK" "No update is ever installed without confirmation."
                ui_pause
                ;;
            *) return;;
        esac
    done
}

startup_splash() {
    [[ -t 1 && "${SKM_NO_ANIMATION:-0}" != "1" ]] || return 0
    clear_screen; hide_cursor
    printf '\n\n  %s◆%s  %s%s%s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$APP_NAME" "$C_RESET"
    printf '  %sKnow every key. Control every grant.%s\n\n' "$C_MUTED" "$C_RESET"
    sleep 0.25
    show_cursor
}

interactive_main() {
    local options
    refresh_host_statuses || true
    startup_splash
    while true; do
        options=(
            "Give Access|Authorize this device or a new client on selected machines"
            "Machines|Add and manage the servers and devices in your key inventory"
            "Keys & Security|Fleet inventory, public key sharing, revoke, and audit"
            "Access Overview|See which managed machine identities are authorized where"
            "Updates|Release checks and safe self-update"
            "Help|Beginner guide and command reference"
            "Exit|Close SSH Key Manager"
        )
        run_menu "Dashboard" "Manage who can access your machines. Private keys always stay on their own device." "${options[@]}"
        case "$MENU_RESULT" in
            0) interactive_access_setup;;
            1) interactive_hosts;;
            2) interactive_security;;
            3) interactive_access_map;;
            4) interactive_updates;;
            5) ui_header "Help"; usage; ui_pause;;
            6|-1) ui_header "Session closed"; printf '\n  %sNo keys moved. No access changed.%s\n\n' "$C_MUTED" "$C_RESET"; return;;
        esac
    done
}
