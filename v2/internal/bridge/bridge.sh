#!/bin/sh
set -eu
umask 077

AK="${SKM2_AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
MANAGED="${SKM2_MANAGED_STATE:-${AK}.skm2.managed}"
RECEIPT="${SKM2_RECEIPT_STATE:-${AK}.skm2.receipt}"
LOCK="${AK}.skm2.lock"
BACKUP="${AK}.skm2.bak"
MANAGED_BACKUP="${MANAGED}.bak"

# sshd invokes a forced command without argv and exposes the requested command
# through SSH_ORIGINAL_COMMAND. Split into positional words without eval. The
# protocol accepts only fixed operation names, revisions, operation IDs and
# SHA256 fingerprints.
if [ "$#" -eq 0 ]; then
  # shellcheck disable=SC2086
  set -- ${SSH_ORIGINAL_COMMAND:-}
fi
cmd="${1:-}"
[ "$#" -eq 0 ] || shift

hash_stream() {
  sha256sum 2>/dev/null || shasum -a 256
}

revision() {
  {
    printf '%s\n' 'SKM2-AUTHORIZED-KEYS'
    [ -f "$AK" ] && cat "$AK" || true
    printf '%s\n' 'SKM2-MANAGED-FINGERPRINTS'
    [ -f "$MANAGED" ] && cat "$MANAGED" || true
  } | hash_stream | awk '{print $1}'
}

refuse_symlinks() {
  [ ! -L "$AK" ] || { echo 'symlinked authorized_keys refused' >&2; exit 20; }
  [ ! -L "$MANAGED" ] || { echo 'symlinked managed state refused' >&2; exit 20; }
  [ ! -L "$RECEIPT" ] || { echo 'symlinked receipt state refused' >&2; exit 20; }
}

valid_token() {
  [ -n "$1" ] || return 1
  case "$1" in *[!A-Za-z0-9_-]*) return 1;; esac
  return 0
}

write_receipt() {
  operation="$1"
  kind="$2"
  before="$3"
  after="$4"
  tmp_receipt="${RECEIPT}.skm2.$$"
  {
    printf 'last_operation=%s\n' "$operation"
    printf 'last_kind=%s\n' "$kind"
    printf 'last_before=%s\n' "$before"
    printf 'last_after=%s\n' "$after"
  } > "$tmp_receipt"
  chmod 600 "$tmp_receipt"
  mv -f "$tmp_receipt" "$RECEIPT"
}

case "$cmd" in
 version)
   [ "$#" -eq 0 ] || { echo 'version takes no arguments' >&2; exit 64; }
   printf '%s\n' 'SKM2-BRIDGE|3'
   ;;

 inspect)
   [ "$#" -eq 0 ] || { echo 'inspect takes no arguments' >&2; exit 64; }
   refuse_symlinks
   printf 'SKM2-STATE|3\nrevision=%s\n' "$(revision)"
   if [ -f "$RECEIPT" ]; then
     while IFS= read -r receipt_line || [ -n "$receipt_line" ]; do
       case "$receipt_line" in
         last_operation=*|last_kind=*|last_before=*|last_after=*) printf '%s\n' "$receipt_line" ;;
       esac
     done < "$RECEIPT"
   fi
   if [ -f "$MANAGED" ]; then
     while IFS= read -r fp || [ -n "$fp" ]; do
       [ -n "$fp" ] && printf 'managed=%s\n' "$fp"
     done < "$MANAGED"
   fi
   printf '%s\n' '--'
   [ -f "$AK" ] && cat "$AK" || true
   ;;

 apply|rollback)
   expected="${1:-}"
   operation="${2:-}"
   [ -n "$expected" ] || { echo 'expected revision required' >&2; exit 21; }
   valid_token "$expected" || { echo 'invalid expected revision' >&2; exit 21; }
   valid_token "$operation" || { echo 'valid operation id required' >&2; exit 21; }
   shift 2 || true
   if [ "$cmd" = rollback ] && [ "$#" -ne 0 ]; then
     echo 'rollback takes no managed fingerprints' >&2
     exit 64
   fi

   refuse_symlinks
   mkdir "$LOCK" 2>/dev/null || { echo 'busy' >&2; exit 23; }
   trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM

   actual="$(revision)"
   [ "$actual" = "$expected" ] || { echo "revision mismatch expected=$expected actual=$actual" >&2; exit 22; }

   mkdir -p "$(dirname "$AK")"
   chmod 700 "$(dirname "$AK")" 2>/dev/null || true
   tmp_ak="${AK}.skm2.$$"
   tmp_managed="${MANAGED}.skm2.$$"

   if [ "$cmd" = rollback ]; then
     [ -f "$BACKUP" ] || { echo 'no rollback backup' >&2; exit 24; }
     [ -f "$MANAGED_BACKUP" ] || { echo 'no rollback managed-state backup' >&2; exit 24; }
     cp "$BACKUP" "$tmp_ak"
     cp "$MANAGED_BACKUP" "$tmp_managed"
   else
     cat > "$tmp_ak"
     : > "$tmp_managed"
     for fp in "$@"; do
       case "$fp" in SHA256:*) ;; *) echo 'invalid managed fingerprint' >&2; rm -f "$tmp_ak" "$tmp_managed"; exit 25;; esac
       printf '%s\n' "$fp" >> "$tmp_managed"
     done
     sort -u "$tmp_managed" -o "$tmp_managed"
   fi

   chmod 600 "$tmp_ak" "$tmp_managed"

   # Re-check after staging. A manual edit that raced the operation is detected
   # even though it does not honor the bridge lock.
   actual="$(revision)"
   [ "$actual" = "$expected" ] || { rm -f "$tmp_ak" "$tmp_managed"; echo "revision mismatch expected=$expected actual=$actual" >&2; exit 22; }

   [ -f "$AK" ] && cp -p "$AK" "$BACKUP" || : > "$BACKUP"
   [ -f "$MANAGED" ] && cp -p "$MANAGED" "$MANAGED_BACKUP" || : > "$MANAGED_BACKUP"
   chmod 600 "$BACKUP" "$MANAGED_BACKUP"

   # Managed metadata is installed first. If the process is interrupted between
   # the two renames, inspect intersects ownership with keys actually present,
   # so the failure mode is conservative rather than destructive.
   mv -f "$tmp_managed" "$MANAGED"
   mv -f "$tmp_ak" "$AK"
   after="$(revision)"

   # The receipt is outside the revision hash. It lets the controller distinguish
   # "mutation committed but SSH response was lost" from unrelated concurrent
   # edits without ever guessing ownership of a changed remote state.
   write_receipt "$operation" "$cmd" "$expected" "$after"
   printf 'SKM2-APPLIED|3\noperation=%s\nrevision=%s\n' "$operation" "$after"
   ;;

 *)
   echo 'restricted SKM2 bridge: unsupported operation' >&2
   exit 64
   ;;
esac
