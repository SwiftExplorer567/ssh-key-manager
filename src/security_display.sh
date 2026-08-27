# shellcheck shell=bash

# Public-key comments are attacker-controlled metadata. Never print terminal
# control characters from them, and prefer canonical registry names when known.
sanitize_text() {
    LC_ALL=C printf '%s' "$1" | tr '[:cntrl:]' '?'
}

key_display_label() {
    local fingerprint="$1" comment="${2:-}" label
    comment=$(sanitize_text "$comment")
    [[ -n "$comment" ]] || comment="unnamed key"
    if declare -F identity_label_for_fingerprint >/dev/null 2>&1; then
        label=$(identity_label_for_fingerprint "$fingerprint" "$comment" 2>/dev/null || true)
        [[ -n "$label" ]] && { printf '%s' "$label"; return; }
    fi
    printf '%s' "$comment"
}
