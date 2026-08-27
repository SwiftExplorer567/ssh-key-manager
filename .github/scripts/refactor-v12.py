from pathlib import Path

path = Path("src/access.sh")
source = path.read_text()

replacements = [
    (
        '''print_authorized_lines() {
    local lines="$1" n=0 line fp comment
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \\#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        n=$((n + 1)); comment=$(key_comment "$line"); [[ -n "$comment" ]] || comment="unnamed key"
        printf '%3d  %-28s %s\\n' "$n" "$comment" "$fp"
    done <<< "$lines"
}''',
        '''print_authorized_lines() {
    local lines="$1" n=0 line fp comment
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \\#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        n=$((n + 1))
        comment=$(key_display_label "$fp" "$(key_comment "$line")")
        printf '%3d  %-28s %s\\n' "$n" "$comment" "$fp"
    done <<< "$lines"
}''',
    ),
    (
        '''print_inventory_lines() {
    local lines="$1" n=0 line fp comment algorithm
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \\#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        algorithm=$(key_algorithm "$line"); comment=$(key_comment "$line")
        [[ -n "$comment" ]] || comment="unnamed key"
        (( ${#comment} > 28 )) && comment="${comment:0:27}…"
        n=$((n + 1))
        printf '    %-12s %-48s %s\\n' "$algorithm" "$fp" "$comment"
    done <<< "$lines"
    (( n > 0 )) || say "    none"
}''',
        '''print_inventory_lines() {
    local lines="$1" n=0 line fp comment algorithm
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \\#* ]] && continue
        fp=$(key_fingerprint "$line"); [[ -n "$fp" ]] || continue
        algorithm=$(key_algorithm "$line")
        comment=$(key_display_label "$fp" "$(key_comment "$line")")
        (( ${#comment} > 28 )) && comment="${comment:0:27}…"
        n=$((n + 1))
        printf '    %-12s %-48s %s\\n' "$algorithm" "$fp" "$comment"
    done <<< "$lines"
    (( n > 0 )) || say "    none"
}''',
    ),
    (
        '''authorized_key_menu_item() {
    local line="$1" fingerprint algorithm comment
    fingerprint=$(key_fingerprint "$line") || return 1
    algorithm=$(key_algorithm "$line"); comment=$(key_comment "$line")
    [[ -n "$comment" ]] || comment="Unnamed key"
    (( ${#comment} > 42 )) && comment="${comment:0:41}…"
    printf '%s|%s · %s' "$comment" "$algorithm" "$fingerprint"
}''',
        '''authorized_key_menu_item() {
    local line="$1" fingerprint algorithm comment
    fingerprint=$(key_fingerprint "$line") || return 1
    algorithm=$(key_algorithm "$line")
    comment=$(key_display_label "$fingerprint" "$(key_comment "$line")")
    (( ${#comment} > 42 )) && comment="${comment:0:41}…"
    printf '%s|%s · %s' "$comment" "$algorithm" "$fingerprint"
}''',
    ),
]

for old, new in replacements:
    if old not in source:
        raise SystemExit("expected access rendering block not found")
    source = source.replace(old, new, 1)
path.write_text(source)

identities = Path("src/identities.sh")
text = identities.read_text()
text = text.replace('IDENTITY_NAMES[$index]="$new_name"', 'IDENTITY_NAMES[index]="$new_name"')
text = text.replace('IDENTITY_STATUSES[$index]="$status"', 'IDENTITY_STATUSES[index]="$status"')
identities.write_text(text)

Path("src/security_display.sh").write_text(
    '''# shellcheck shell=bash

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
'''
)
