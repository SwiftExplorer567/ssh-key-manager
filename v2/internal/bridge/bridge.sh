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
# through SSH_ORIGINAL_COMMAND. Split into positional words without eval.
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
   printf '%s\n' 'SKM2-BRIDGE|2'
   ;;

 capabilities)
   [ "$#" -eq 0 ] || { echo 'capabilities takes no arguments' >&2; exit 64; }
   printf '%s\n' 'mutation-receipts-v1'
   ;;

 inspect)
   [ "$#" -eq 0 ] || { echo 'inspect takes no arguments' >&2; exit 64; }
   refuse_symlinks
   printf 'SKM2-STATE|2\nrevision=%s\n' "$(revision)"
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
   [ -n "$expected" ] || { echo 'expected revision required' >&2; exit 21; }
   valid_token "$expected" || { echo 'invalid expected revision' >&2; exit 21; }
   shift || true

   # Receipt-aware beta.2 clients add an op_* token after the expected revision.
   # Beta.1 clients do not. Supporting both syntaxes keeps newly enrolled targets
   # compatible with the already published beta.1 controller.
   operation="legacy"
   if [ "$#" -gt 0 ]; then
     case "$1" in
       op_*) operation="$1"; shift ;;
     esac
   fi
   valid_token "$operation" || { echo 'invalid operation id' >&2; exit 21; }
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

   actual="$(revision)"
   [ "$actual" = "$expected" ] || { rm -f "$tmp_ak" "$tmp_managed"; echo "revision mismatch expected=$expected actual=$actual" >&2; exit 22; }

   [ -f "$AK" ] && cp -p "$AK" "$BACKUP" || : > "$BACKUP"
   [ -f "$MANAGED" ] && cp -p "$MANAGED" "$MANAGED_BACKUP" || : > "$MANAGED_BACKUP"
   chmod 600 "$BACKUP" "$MANAGED_BACKUP"

   mv -f "$tmp_managed" "$MANAGED"
   mv -f "$tmp_ak" "$AK"
   after="$(revision)"

   # Receipt metadata is outside the revision hash. It lets a receipt-aware
   # controller prove that its own operation committed when an SSH response is
   # lost, without guessing based only on a changed authorized_keys revision.
   write_receipt "$operation" "$cmd" "$expected" "$after"
   printf 'SKM2-APPLIED|2\noperation=%s\nrevision=%s\n' "$operation" "$after"
   ;;

 *)
   echo 'restricted SKM2 bridge: unsupported operation' >&2
   exit 64
   ;;
esac
