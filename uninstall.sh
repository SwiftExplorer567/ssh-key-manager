#!/usr/bin/env bash
# SSH Key Manager uninstaller. SSH keys are never removed.

set -o errexit
set -o nounset

PURGE=0
YES=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --yes|-y) YES=1 ;;
        -h|--help)
            echo "Usage: uninstall.sh [--yes] [--purge]"
            echo "--purge also removes SKM host configuration; ~/.ssh is never removed."
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if (( YES == 0 )); then
    [[ -t 0 ]] || { echo "Use --yes for non-interactive uninstall." >&2; exit 2; }
    printf 'Remove SSH Key Manager binaries? SSH keys will remain untouched. [y/N] '
    IFS= read -r answer
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Cancelled."; exit 0; }
fi

remove_from() {
    local dir="$1"
    rm -f "$dir/ssh-key-manager" "$dir/skm" "$dir/keymanager"
}

remove_from "$HOME/.local/bin"
if [[ -e /usr/local/bin/ssh-key-manager || -L /usr/local/bin/skm || -L /usr/local/bin/keymanager ]]; then
    if [[ -w /usr/local/bin ]]; then remove_from /usr/local/bin
    elif command -v sudo >/dev/null 2>&1; then
        sudo rm -f /usr/local/bin/ssh-key-manager /usr/local/bin/skm /usr/local/bin/keymanager
    else
        echo "Could not remove /usr/local/bin installation (sudo unavailable)." >&2
    fi
fi

if (( PURGE == 1 )); then
    config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager"
    rm -rf "$config_dir"
    echo "Removed configuration: $config_dir"
else
    echo "Kept host configuration. Re-run with --purge to remove it."
fi
echo "Uninstalled SSH Key Manager. ~/.ssh and all SSH keys were preserved."
