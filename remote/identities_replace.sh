#!/usr/bin/env sh
set -eu
umask 077

config_dir="${SKM_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager}"
target="$config_dir/identities.conf"
mkdir -p "$config_dir"
chmod 700 "$config_dir" 2>/dev/null || true

if [ -L "$target" ]; then
    echo "Refusing to replace symlinked identity registry." >&2
    exit 1
fi

tmp=$(mktemp "$config_dir/identities.sync.XXXXXX")
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM
cat > "$tmp"
chmod 600 "$tmp"

awk -F'|' '
    NF != 4 { exit 1 }
    length($1) < 1 || length($1) > 63 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
    $2 !~ /^SHA256:[A-Za-z0-9+\/=_.-]+$/ { exit 1 }
    $3 != "device" && $3 != "server" && $3 != "service" && $3 != "other" { exit 1 }
    $4 != "active" && $4 != "retired" { exit 1 }
    seen_name[$1]++ { exit 1 }
    seen_fp[$2]++ { exit 1 }
    END { if (NR == 0) exit 1 }
' "$tmp" || {
    echo "Invalid identity registry payload." >&2
    exit 1
}

stamp=$(date +%Y%m%d-%H%M%S)
if [ -f "$target" ]; then
    backup="$target.pre-sync-$stamp-$$"
    cp -p "$target" "$backup"
    chmod 600 "$backup" 2>/dev/null || true
fi

mv -f "$tmp" "$target"
chmod 600 "$target"
trap - EXIT HUP INT TERM
count=$(wc -l < "$target" | tr -d ' ')
printf 'SYNCED %s\n' "$count"
