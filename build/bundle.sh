#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUTPUT="${1:-$ROOT/ssh-key-manager}"
TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/skm-bundle.XXXXXX")
TMP_CHECKSUM=$(mktemp "${TMPDIR:-/tmp}/skm-checksum.XXXXXX")
trap 'rm -f "$TMP_FILE" "$TMP_CHECKSUM"' EXIT HUP INT TERM

append_module() {
    local path="$1"
    printf '\n# --- %s ---\n' "${path#"$ROOT"/}"
    sed '1{/^#!\/usr\/bin\/env bash$/d;}' "$path"
}

{
    printf '#!/usr/bin/env bash\n'
    append_module "$ROOT/src/runtime.sh"
    append_module "$ROOT/src/ui.sh"
    append_module "$ROOT/src/hosts.sh"
    append_module "$ROOT/src/host_trust.sh"
    append_module "$ROOT/src/ssh_transport.sh"
    printf '\n# --- embedded remote programs ---\n'
    printf 'REMOTE_ADD_SCRIPT=%q\n' "$(<"$ROOT/remote/authorized_add.sh")"
    printf 'REMOTE_REMOVE_SCRIPT=%q\n' "$(<"$ROOT/remote/authorized_remove.sh")"
    printf 'REMOTE_IDENTITIES_SYNC_SCRIPT=%q\n' "$(<"$ROOT/remote/identities_replace.sh")"
    append_module "$ROOT/src/access.sh"
    append_module "$ROOT/src/identities.sh"
    append_module "$ROOT/src/policy.sh"
    append_module "$ROOT/src/security_display.sh"
    append_module "$ROOT/src/fleet.sh"
    append_module "$ROOT/src/updates.sh"
    append_module "$ROOT/src/cli.sh"
} > "$TMP_FILE"

chmod 755 "$TMP_FILE"
mv -f "$TMP_FILE" "$OUTPUT"
if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$OUTPUT" | awk '{print $1}')
else
    digest=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
fi
printf '%s  ssh-key-manager\n' "$digest" > "$TMP_CHECKSUM"
chmod 644 "$TMP_CHECKSUM"
mv -f "$TMP_CHECKSUM" "$OUTPUT.sha256"
trap - EXIT HUP INT TERM
