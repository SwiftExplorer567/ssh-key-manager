#!/bin/sh

set -eu
umask 077
ssh_dir="$HOME/.ssh"
auth="$ssh_dir/authorized_keys"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"
[ ! -L "$auth" ] || { echo "unsafe-symlink" >&2; exit 20; }
incoming=$(mktemp "$ssh_dir/skm.in.XXXXXX")
tmp=$(mktemp "$ssh_dir/authorized_keys.skm.XXXXXX")
lock="$ssh_dir/.skm-authorized-keys.lock"
cleanup() { rm -f "$incoming" "$tmp"; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
cat > "$incoming"
blob=$(awk 'NR==1 {print $2}' "$incoming")
[ -n "$blob" ] || { echo "invalid-key" >&2; exit 21; }
n=0
while ! mkdir "$lock" 2>/dev/null; do n=$((n+1)); [ "$n" -lt 30 ] || exit 22; sleep 1; done
[ -f "$auth" ] && cat "$auth" > "$tmp"
if awk -v wanted="$blob" '{ for (i=1; i<=NF; i++) if ($i == wanted) found=1 } END { exit !found }' "$tmp"; then
  echo exists
else
  cat "$incoming" >> "$tmp"
  echo added
fi
chmod 600 "$tmp"
if [ -f "$auth" ]; then cp -p "$auth" "$auth.skm.bak" 2>/dev/null || true; fi
mv -f "$tmp" "$auth"
rmdir "$lock"
trap - EXIT HUP INT TERM
rm -f "$incoming"
