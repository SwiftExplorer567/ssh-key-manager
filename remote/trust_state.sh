#!/usr/bin/env sh
set -eu

config_dir="${SKM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager}"
identities="$config_dir/identities.conf"
policy="$config_dir/policy.conf"

[ ! -L "$identities" ] || { echo "unsafe identity registry symlink" >&2; exit 31; }
[ ! -L "$policy" ] || { echo "unsafe policy symlink" >&2; exit 32; }

printf 'SKM-REMOTE-TRUST|1\n'
if [ -f "$identities" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        printf 'IDENTITY|%s\n' "$line"
    done < "$identities"
fi
if [ -f "$policy" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        printf 'POLICY|%s\n' "$line"
    done < "$policy"
fi
