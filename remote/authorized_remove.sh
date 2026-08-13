#!/bin/sh

set -eu
umask 077
ssh_dir="$HOME/.ssh"
auth="$ssh_dir/authorized_keys"
[ -f "$auth" ] && [ ! -L "$auth" ] || exit 20
incoming=$(mktemp "$ssh_dir/skm.remove.XXXXXX")
tmp=$(mktemp "$ssh_dir/authorized_keys.skm.XXXXXX")
lock="$ssh_dir/.skm-authorized-keys.lock"
cleanup() { rm -f "$incoming" "$tmp"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
cat > "$incoming"
blob=$(cat "$incoming")
[ -n "$blob" ] || exit 21
n=0
while ! mkdir "$lock" 2>/dev/null; do n=$((n+1)); [ "$n" -lt 30 ] || exit 22; sleep 1; done
awk -v wanted="$blob" '{ found=0; for (i=1; i<=NF; i++) if ($i == wanted) found=1; if (!found) print }' "$auth" > "$tmp"
chmod 600 "$tmp"
cp -p "$auth" "$auth.skm.bak" 2>/dev/null || true
mv -f "$tmp" "$auth"
rmdir "$lock"
trap - EXIT HUP INT TERM
rm -f "$incoming"
