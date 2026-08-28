#!/bin/sh
set -eu
umask 077
AK="${SKM2_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
LOCK="${AK}.skm2.lock"
BACKUP="${AK}.skm2.bak"
cmd="${1:-${SSH_ORIGINAL_COMMAND:-}}"
revision(){ if [ -f "$AK" ]; then (sha256sum "$AK" 2>/dev/null || shasum -a 256 "$AK") | awk '{print $1}'; else printf '%s\n' empty; fi; }
case "$cmd" in
 version) printf '%s\n' 'SKM2-BRIDGE|1' ;;
 inspect)
   [ ! -L "$AK" ] || { echo 'symlinked authorized_keys refused' >&2; exit 20; }
   printf 'SKM2-STATE|1\nrevision=%s\n' "$(revision)"
   [ -f "$AK" ] && cat "$AK" || true
   ;;
 apply|rollback)
   expected="${2:-}"; [ -n "$expected" ] || { echo 'expected revision required' >&2; exit 21; }
   actual="$(revision)"; [ "$actual" = "$expected" ] || { echo "revision mismatch expected=$expected actual=$actual" >&2; exit 22; }
   [ ! -L "$AK" ] || { echo 'symlinked authorized_keys refused' >&2; exit 20; }
   mkdir "$LOCK" 2>/dev/null || { echo 'busy' >&2; exit 23; }; trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
   mkdir -p "$(dirname "$AK")"; chmod 700 "$(dirname "$AK")" 2>/dev/null || true
   tmp="${AK}.skm2.$$"
   if [ "$cmd" = rollback ]; then [ -f "$BACKUP" ] || { echo 'no rollback backup' >&2; exit 24; }; cp "$BACKUP" "$tmp"; else cat > "$tmp"; fi
   chmod 600 "$tmp"
   [ -f "$AK" ] && cp -p "$AK" "$BACKUP" || true
   mv -f "$tmp" "$AK"
   printf 'SKM2-APPLIED|1\nrevision=%s\n' "$(revision)"
   ;;
 *) echo 'restricted SKM2 bridge: unsupported operation' >&2; exit 64 ;;
esac
