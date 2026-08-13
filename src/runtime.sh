#!/usr/bin/env bash
# SSH Key Manager v1 — understandable, directional SSH access management.

set -o pipefail
umask 077

VERSION="1.0.0"
APP_NAME="SSH Key Manager"
REPOSITORY="SwiftExplorer567/ssh-key-manager"

CONFIG_DIR="${SKM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager}"
HOSTS_FILE="${SKM_HOSTS_FILE:-$CONFIG_DIR/servers.conf}"
SETTINGS_FILE="${SKM_SETTINGS_FILE:-$CONFIG_DIR/config}"
SSH_DIR="${SKM_SSH_DIR:-$HOME/.ssh}"
MANAGED_KEY="${SKM_MANAGED_KEY:-$SSH_DIR/id_ed25519_skm}"
AUTHORIZED_KEYS="${SKM_AUTHORIZED_KEYS:-$SSH_DIR/authorized_keys}"
STRICT_HOST_KEY_CHECKING="${SKM_STRICT_HOST_KEY_CHECKING:-accept-new}"
UPDATE_STATE_FILE="${SKM_UPDATE_STATE_FILE:-$CONFIG_DIR/update.state}"
AUTO_UPDATE_CHECK="${SKM_AUTO_UPDATE_CHECK:-true}"

declare -a HOST_NAMES HOST_USERS HOST_ADDRS HOST_PORTS HOST_STATUSES
MENU_RESULT=-1
SELECTED_HOST=""
SELECTED_HOST_INDEX=-1
RESOLVED_HOST_INDEX=-1
LATEST_VERSION=""
UPDATE_AVAILABLE=0

if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
    C_ACCENT=$'\033[38;5;161m'
    C_SILVER=$'\033[38;5;250m'
    C_MUTED=$'\033[38;5;245m'
    C_DIM=$'\033[2m'
    C_REVERSE=$'\033[7m'
    C_GREEN=$'\033[38;5;114m'
    C_YELLOW=$'\033[38;5;221m'
    C_RED=$'\033[38;5;203m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_ACCENT="" C_SILVER="" C_MUTED="" C_DIM="" C_REVERSE=""
    C_GREEN="" C_YELLOW="" C_RED="" C_BOLD="" C_RESET=""
fi

cleanup_terminal() {
    if [[ -t 0 ]]; then
        stty echo 2>/dev/null || true
        tput cnorm 2>/dev/null || true
    fi
}
trap cleanup_terminal EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

hide_cursor() { if [[ -t 1 ]]; then tput civis 2>/dev/null || true; fi; }
show_cursor() { if [[ -t 1 ]]; then tput cnorm 2>/dev/null || true; fi; }

say() { printf '%s\n' "$*"; }
info() { printf '%sinfo%s  %s\n' "$C_ACCENT" "$C_RESET" "$*"; }
ok() { printf '%sok%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarn%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
fail() { printf '%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() { fail "$*"; exit 1; }

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

file_mode() {
    if [[ "$(uname -s)" == "Darwin" ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [[ "${SKM_ASSUME_YES:-0}" == "1" ]]; then return 0; fi
    [[ -t 0 ]] || return 1
    if [[ "$default" == "y" ]]; then
        printf '%s [Y/n] ' "$prompt"
    else
        printf '%s [y/N] ' "$prompt"
    fi
    IFS= read -r answer || return 1
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

prompt() {
    local label="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r value || return 1
    printf '%s' "${value:-$default}"
}


ensure_runtime() {
    command -v ssh >/dev/null 2>&1 || die "OpenSSH client is required (ssh)."
    command -v ssh-keygen >/dev/null 2>&1 || die "OpenSSH key tools are required (ssh-keygen)."
    mkdir -p "$CONFIG_DIR" "$SSH_DIR" || die "Cannot create configuration directories."
    chmod 700 "$CONFIG_DIR" "$SSH_DIR" 2>/dev/null || true
    [[ -e "$HOSTS_FILE" ]] || : > "$HOSTS_FILE"
    chmod 600 "$HOSTS_FILE" 2>/dev/null || true
}

load_settings() {
    [[ -f "$SETTINGS_FILE" ]] || return 0
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        case "$key" in
            BRAND) [[ "$value" != *$'\n'* ]] && APP_NAME="$value" ;;
            STRICT_HOST_KEY_CHECKING)
                [[ "$value" == "yes" || "$value" == "accept-new" ]] && STRICT_HOST_KEY_CHECKING="$value"
                ;;
            AUTO_UPDATE_CHECK)
                [[ "$value" == "true" || "$value" == "false" ]] && AUTO_UPDATE_CHECK="$value"
                ;;
        esac
    done < "$SETTINGS_FILE"
}

valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; }
valid_user() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]]; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
