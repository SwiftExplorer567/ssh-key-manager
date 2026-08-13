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
    printf '\n  %s◆%s %s%s%s  %sv%s%s%b\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$APP_NAME" "$C_RESET" "$C_MUTED" "$VERSION" "$C_RESET" "$update_text"
    printf '  %s%s%s  %s·%s  %s%d machine%s%s\n' "$C_SILVER" "$section" "$C_RESET" "$C_MUTED" "$C_RESET" "$C_MUTED" "$hosts" "$plural" "$C_RESET"
    ui_rule "$width"
}

ui_notice() {
    local tone="$1" title="$2" body="$3" color="$C_ACCENT"
    case "$tone" in success) color="$C_GREEN";; warning) color="$C_YELLOW";; danger) color="$C_RED";; esac
    printf '\n  %s%s%s  %s%s%s\n' "$color" "$title" "$C_RESET" "$C_MUTED" "$body" "$C_RESET"
}

render_menu() {
    local title="$1" subtitle="$2" selected="$3"; shift 3
    local options=("$@") i label description marker width label_width=25 max_desc
    width=$(terminal_width)
    (( width < 72 )) && label_width=20
    max_desc=$((width - label_width - 10)); (( max_desc < 10 )) && max_desc=10
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
            printf '  %b %s%-*s%s  %s%s%s\n' "$marker" "$C_REVERSE$C_BOLD" "$label_width" "$label" "$C_RESET" "$C_SILVER" "$description" "$C_RESET"
        else
            printf '    %s%-*s%s  %s%s%s\n' "$C_SILVER" "$label_width" "$label" "$C_RESET" "$C_MUTED" "$description" "$C_RESET"
        fi
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
        ui_header "$title"; ui_notice warning "No remote machines" "Add one from Machines first."; ui_pause; return 1
    fi
    run_menu "$title" "Choose by name; no key files are shown here." "${options[@]}"
    (( MENU_RESULT >= 0 )) || return 1
    SELECTED_HOST_INDEX=${indices[$MENU_RESULT]}
    SELECTED_HOST="${HOST_NAMES[$SELECTED_HOST_INDEX]}"
}

interactive_quick_connect() {
    select_host "Quick Connect" true || return
    ui_header "Connecting"
    printf '\n  %s%s%s\n  %s%s@%s · port %s%s\n\n' "$C_BOLD" "$SELECTED_HOST" "$C_RESET" "$C_MUTED" \
        "${HOST_USERS[$SELECTED_HOST_INDEX]}" "${HOST_ADDRS[$SELECTED_HOST_INDEX]}" "${HOST_PORTS[$SELECTED_HOST_INDEX]}" "$C_RESET"
    connect_host "$SELECTED_HOST" || { ui_notice danger "Connection failed" "Check access status or the machine address."; ui_pause; }
    refresh_host_statuses || true
}

interactive_access_setup() {
    local preselected="${1:-}" name
    if [[ -n "$preselected" ]]; then
        require_host "$preselected" || return; SELECTED_HOST="$preselected"; SELECTED_HOST_INDEX=$RESOLVED_HOST_INDEX
        is_local_host "$SELECTED_HOST_INDEX" && { ui_header "Access Setup"; ui_notice warning "Local machine selected" "Choose a remote machine for SSH access."; ui_pause; return; }
    else
        select_host "Access Setup" true || return
    fi
    name="$SELECTED_HOST"
    local options=(
        "From here to $name|Use $name from this machine without a password"
        "From $name to here|Let $name connect back to this machine"
        "Both directions|Two public grants; each private key stays at home"
        "Back|Return without changing access"
    )
    run_menu "Access Setup" "Select the direction. The next screen confirms the exact result." "${options[@]}"
    case "$MENU_RESULT" in
        0) ui_header "Confirm Access"; ui_notice warning "THIS MACHINE  →  $name" "Your public key will be authorized on $name."; confirm "Continue?" y && access_grant "$name"; ui_pause;;
        1) ui_header "Confirm Access"; ui_notice warning "$name  →  THIS MACHINE" "$name's public key will be authorized here."; confirm "Continue?" y && access_receive "$name"; ui_pause;;
        2) ui_header "Confirm Access"; ui_notice warning "THIS MACHINE  ↔  $name" "Private keys stay separate; only public keys cross."; confirm "Continue?" y && access_link "$name"; ui_pause;;
        *) return;;
    esac
    refresh_host_statuses || true
}

interactive_access_map() {
    ui_header "Access Map"
    printf '\n  %sArrows show who can initiate an SSH connection.%s\n' "$C_MUTED" "$C_RESET"
    access_status || true
    ui_pause
}

interactive_add_host() {
    local name user host port
    ui_header "Add Machine"
    printf '\n  %sUse a short name you will type with: skm connect NAME%s\n\n' "$C_MUTED" "$C_RESET"
    name=$(prompt "  Machine name") || return
    user=$(prompt "  SSH user" "$USER") || return
    host=$(prompt "  Hostname or IP") || return
    port=$(prompt "  SSH port" "22") || return
    if ! valid_name "$name" || ! valid_user "$user" || ! valid_host "$host" || ! valid_port "$port"; then
        ui_notice danger "Invalid machine details" "Names cannot contain spaces; check user, host, and port."; ui_pause; return
    fi
    if host_index "$name" >/dev/null 2>&1; then ui_notice danger "Name already exists" "Choose another short name."; ui_pause; return; fi
    host_add "$name" "$user" "$host" "$port" || { ui_pause; return; }
    load_hosts; refresh_host_statuses || true
    if ! is_local_host "$(host_index "$name")" && confirm "Set up passwordless access now?" y; then interactive_access_setup "$name"; else ui_pause; fi
}

interactive_hosts() {
    local options name
    while true; do
        options=(
            "Browse & test|See connection details and test passwordless SSH"
            "Add machine|Register a server, VM, NAS, or workstation"
            "Remove machine|Remove only the SKM record; keys stay untouched"
            "Refresh status|Check all saved machines again"
            "Back|Return to dashboard"
        )
        run_menu "Machines" "${#HOST_NAMES[@]} saved · statuses use key-only SSH checks." "${options[@]}"
        case "$MENU_RESULT" in
            0)
                select_host "Machine Details" false || continue
                ui_header "${SELECTED_HOST}"
                printf '\n  %sUser%s     %s\n  %sAddress%s  %s\n  %sPort%s     %s\n  %sStatus%s   %b\n' \
                    "$C_MUTED" "$C_RESET" "${HOST_USERS[$SELECTED_HOST_INDEX]}" "$C_MUTED" "$C_RESET" "${HOST_ADDRS[$SELECTED_HOST_INDEX]}" \
                    "$C_MUTED" "$C_RESET" "${HOST_PORTS[$SELECTED_HOST_INDEX]}" "$C_MUTED" "$C_RESET" "$(host_status_text "$SELECTED_HOST_INDEX")"
                printf '\n'; host_test "$SELECTED_HOST" || true; ui_pause
                ;;
            1) interactive_add_host;;
            2)
                select_host "Remove Machine" false || continue; name="$SELECTED_HOST"
                ui_header "Remove Machine"; ui_notice danger "$name" "Only its SKM record is removed; SSH keys remain unchanged."
                if confirm "Remove $name?" n; then host_remove "$name" && load_hosts && refresh_host_statuses; fi; ui_pause
                ;;
            3) ui_header "Refreshing"; refresh_host_statuses; ui_notice success "Status refreshed" "Key-only connectivity checks completed."; ui_pause;;
            *) return;;
        esac
    done
}

interactive_security() {
    local options path comment
    while true; do
        options=(
            "Key inventory|See identities owned here and keys allowed in"
            "Create ED25519 key|Generate a new passphrase-capable identity"
            "Allow pasted public key|Grant another machine access to this one"
            "Revoke remote access|Remove a selected key from a remote machine"
            "Security check|Audit permissions, symlinks, and legacy algorithms"
            "Back|Return to dashboard"
        )
        run_menu "Keys & Security" "Private keys are never displayed or transferred." "${options[@]}"
        case "$MENU_RESULT" in
            0) ui_header "Key Inventory"; key_list; ui_pause;;
            1)
                ui_header "Create ED25519 Key"; path=$(prompt "  Private key path" "$SSH_DIR/id_ed25519_$(date +%Y%m%d)") || continue
                comment=$(prompt "  Label" "$(whoami)@$(hostname)") || continue
                if [[ -e "$path" || -e "$path.pub" ]]; then ui_notice danger "Key already exists" "$path"; else key_generate "$path" "$comment" || true; fi; ui_pause
                ;;
            2) ui_header "Allow Access Here"; access_allow_local - || true; ui_pause;;
            3) select_host "Revoke Access On" true && access_revoke_remote "$SELECTED_HOST"; ui_pause;;
            4) ui_header "Security Check"; doctor || true; ui_pause;;
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
    printf '  %sSecure access, clearly directed.%s\n\n' "$C_MUTED" "$C_RESET"
    sleep 0.25
    show_cursor
}

interactive_main() {
    local options
    refresh_host_statuses || true
    startup_splash
    while true; do
        options=(
            "Quick Connect|Open SSH to a saved machine"
            "Set Up Access|One-way or two-way passwordless access"
            "Access Map|See the direction of every managed connection"
            "Machines|Add, inspect, test, or remove machines"
            "Keys & Security|Identity inventory, grants, revoke, and audit"
            "Updates|Release checks and safe self-update"
            "Help|Mental model and command reference"
            "Exit|Close SSH Key Manager"
        )
        run_menu "Dashboard" "Private keys stay on the machine that created them." "${options[@]}"
        case "$MENU_RESULT" in
            0) interactive_quick_connect;;
            1) interactive_access_setup;;
            2) interactive_access_map;;
            3) interactive_hosts;;
            4) interactive_security;;
            5) interactive_updates;;
            6) ui_header "Help"; usage; ui_pause;;
            7|-1) ui_header "Session closed"; printf '\n  %sNo keys moved. No access changed.%s\n\n' "$C_MUTED" "$C_RESET"; return;;
        esac
    done
}
