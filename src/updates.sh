# shellcheck shell=bash

version_is_newer() {
    local candidate="$1" current="$2" c1=0 c2=0 c3=0 v1=0 v2=0 v3=0 IFS=.
    read -r c1 c2 c3 <<< "$candidate"
    read -r v1 v2 v3 <<< "$current"
    (( 10#${c1:-0} > 10#${v1:-0} )) && return 0
    (( 10#${c1:-0} < 10#${v1:-0} )) && return 1
    (( 10#${c2:-0} > 10#${v2:-0} )) && return 0
    (( 10#${c2:-0} < 10#${v2:-0} )) && return 1
    (( 10#${c3:-0} > 10#${v3:-0} ))
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

verify_checksum_file() {
    local file="$1" checksum_file="$2" expected actual
    expected=$(awk 'NR == 1 {print $1}' "$checksum_file")
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
    [[ ${#expected} -eq 64 && "$expected" != *[!0-9a-f]* ]] || return 1
    actual=$(sha256_file "$file") || return 1
    [[ "$actual" == "$expected" ]]
}

latest_release_version() {
    if [[ -n "${SKM_TEST_LATEST_VERSION:-}" ]]; then printf '%s' "$SKM_TEST_LATEST_VERSION"; return 0; fi
    command -v curl >/dev/null 2>&1 || return 1
    local effective version
    effective=$(curl --fail --silent --show-error --location --max-time 4 \
        --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/$REPOSITORY/releases/latest") || return 1
    version="${effective##*/}"; version="${version#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s' "$version"
}

cache_update_version() {
    local version="$1" tmp
    tmp=$(mktemp "$CONFIG_DIR/update.state.XXXXXX") || return 1
    printf '%s|%s\n' "$version" "$(date +%s)" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$UPDATE_STATE_FILE"
}

apply_update_version() {
    local version="$1"
    LATEST_VERSION="$version"; UPDATE_AVAILABLE=0
    if version_is_newer "$version" "$VERSION"; then UPDATE_AVAILABLE=1; fi
}

check_for_updates() {
    local force="${1:-false}" cached="" checked_at=0 now age latest
    [[ "$AUTO_UPDATE_CHECK" == "true" || "$force" == "true" ]] || return 0
    if [[ -f "$UPDATE_STATE_FILE" ]]; then
        IFS='|' read -r cached checked_at < "$UPDATE_STATE_FILE" || true
        [[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0
    fi
    now=$(date +%s); age=$((now - checked_at))
    if [[ "$force" != "true" && -n "$cached" && $age -lt 86400 ]]; then apply_update_version "$cached"; return 0; fi
    latest=$(latest_release_version 2>/dev/null) || { [[ -n "$cached" ]] && apply_update_version "$cached"; return 1; }
    cache_update_version "$latest" || true
    apply_update_version "$latest"
}

resolve_executable_path() {
    local target="$0" link dir
    if [[ "$target" != /* ]]; then target="$(pwd)/$target"; fi
    while [[ -L "$target" ]]; do
        link=$(readlink "$target") || break
        if [[ "$link" == /* ]]; then target="$link"; else dir=$(cd "$(dirname "$target")" && pwd); target="$dir/$link"; fi
    done
    printf '%s' "$target"
}

install_latest_update() {
    local latest target tmp_dir downloaded checksum_file downloaded_version staged asset_base
    check_for_updates true || { fail "Could not reach the GitHub release service."; return 1; }
    latest="$LATEST_VERSION"
    if [[ -z "$latest" || $UPDATE_AVAILABLE -ne 1 ]]; then ok "You already have the latest version (v$VERSION)."; return 0; fi
    target=$(resolve_executable_path)
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/skm-update.XXXXXX") || return 1
    downloaded="$tmp_dir/ssh-key-manager"
    checksum_file="$tmp_dir/ssh-key-manager.sha256"
    asset_base="https://github.com/$REPOSITORY/releases/download/v$latest"
    info "Downloading versioned release tag v$latest over HTTPS…"
    if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 20 \
        "$asset_base/ssh-key-manager" --output "$downloaded" ||
       ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 20 \
        "$asset_base/ssh-key-manager.sha256" --output "$checksum_file"; then
        rm -rf "$tmp_dir"; fail "Update download failed."; return 1
    fi
    if ! verify_checksum_file "$downloaded" "$checksum_file"; then
        rm -rf "$tmp_dir"; fail "Downloaded release checksum verification failed; nothing was changed."; return 1
    fi
    downloaded_version=$(sed -n 's/^VERSION="\([0-9.]*\)"/\1/p' "$downloaded" | head -1)
    if [[ "$downloaded_version" != "$latest" ]] || ! grep -q '^#!/usr/bin/env bash$' "$downloaded" || ! bash -n "$downloaded"; then
        rm -rf "$tmp_dir"; fail "Downloaded release failed validation; nothing was changed."; return 1
    fi
    chmod 755 "$downloaded"
    if [[ -w "$target" && -w "$(dirname "$target")" ]]; then
        cp -p "$target" "$target.previous" || { rm -rf "$tmp_dir"; return 1; }
        staged="$target.skm-new"
        cp "$downloaded" "$staged" && chmod 755 "$staged" && mv -f "$staged" "$target"
    elif command -v sudo >/dev/null 2>&1; then
        show_cursor
        sudo cp -p "$target" "$target.previous" && sudo install -m 755 "$downloaded" "$target"
    else
        rm -rf "$tmp_dir"; fail "No permission to update $target and sudo is unavailable."; return 1
    fi
    rm -rf "$tmp_dir"
    ok "Updated v$VERSION -> v$latest. Backup: $target.previous"
    return 0
}

save_boolean_setting() {
    local setting="$1" value="$2" tmp
    tmp=$(mktemp "$CONFIG_DIR/config.XXXXXX") || return 1
    if [[ -f "$SETTINGS_FILE" ]]; then awk -F= -v key="$setting" '$1 != key { print }' "$SETTINGS_FILE" > "$tmp"; fi
    printf '%s="%s"\n' "$setting" "$value" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$SETTINGS_FILE"
}
