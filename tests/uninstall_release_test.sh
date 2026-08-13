#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

unsafe_install_prefix_fails() { HOME="$TEST_ROOT/unsafe-install-home" bash "$ROOT/install.sh" --prefix / >/dev/null 2>&1; }
unsafe_uninstall_prefix_fails() { HOME="$TEST_ROOT/unsafe-uninstall-home" bash "$ROOT/uninstall.sh" --yes --prefix / >/dev/null 2>&1; }
assert_false "installer rejects the filesystem root as a prefix" unsafe_install_prefix_fails
assert_false "uninstaller rejects the filesystem root as a prefix" unsafe_uninstall_prefix_fails

install_prefix="$TEST_ROOT/custom/bin"
installer_home="$TEST_ROOT/installer-home"
HOME="$installer_home" bash "$ROOT/install.sh" --prefix "$install_prefix" >/dev/null
assert_true "custom-prefix install creates the executable" test -x "$install_prefix/ssh-key-manager"
HOME="$installer_home" bash "$ROOT/uninstall.sh" --yes --prefix "$install_prefix" >/dev/null
assert_false "custom-prefix uninstall removes the executable" test -e "$install_prefix/ssh-key-manager"
assert_false "custom-prefix uninstall removes the skm alias" test -e "$install_prefix/skm"
assert_false "custom-prefix uninstall removes the keymanager alias" test -e "$install_prefix/keymanager"

purge_home="$TEST_ROOT/purge-home"
purge_config="$purge_home/.config/ssh-key-manager"
mkdir -p "$purge_config"
printf 'fixture\n' > "$purge_config/servers.conf"
HOME="$purge_home" bash "$ROOT/uninstall.sh" --yes --purge --prefix "$TEST_ROOT/purge-bin" >/dev/null
assert_false "purge removes SKM configuration" test -e "$purge_config"
assert_true "purge preserves the SSH directory boundary" test ! -e "$purge_home/.ssh"

if [[ "${SKM_RELEASE_TEST_CHILD:-0}" != "1" ]]; then
    release_repo="$TEST_ROOT/release-repo"
    release_current=$(sed -n 's/^VERSION="\([0-9.]*\)"/\1/p' "$ROOT/src/runtime.sh" | head -1)
    IFS=. read -r release_major release_minor release_patch <<< "$release_current"
    release_test_version="$release_major.$release_minor.$((release_patch + 1))"
    rollback_test_version="$release_major.$release_minor.$((release_patch + 2))"
    cp -R "$ROOT" "$release_repo"
    git -C "$release_repo" config user.name "SKM Tests"
    git -C "$release_repo" config user.email "skm-tests@example.invalid"
    git -C "$release_repo" add -A
    git -C "$release_repo" commit -m "test: release fixture" >/dev/null
    SKM_RELEASE_TEST_CHILD=1 bash "$release_repo/release.sh" "$release_test_version" >/dev/null
    assert_eq "$release_test_version" "$(HOME="$TEST_ROOT/release-home" SKM_TESTING=0 "$release_repo/ssh-key-manager" version)" "release rebuilds the bundled executable"
    assert_true "release updates installer version" grep -q "^VERSION=\"$release_test_version\"$" "$release_repo/install.sh"
    assert_true "release updates source version" grep -q "^VERSION=\"$release_test_version\"$" "$release_repo/src/runtime.sh"
    release_tag_exists() { git -C "$release_repo" rev-parse -q --verify "refs/tags/v$release_test_version" >/dev/null; }
    assert_true "release creates the annotated tag" release_tag_exists
    assert_eq "" "$(git -C "$release_repo" status --short)" "release leaves a clean worktree"

    failing_bin="$TEST_ROOT/release-failing-bin"
    mkdir -p "$failing_bin"
    printf '%s\n' '#!/bin/sh' 'exit 1' > "$failing_bin/make"
    chmod 755 "$failing_bin/make"
    failed_release_rolls_back() {
        PATH="$failing_bin:$PATH" bash "$release_repo/release.sh" "$rollback_test_version" >/dev/null 2>&1
    }
    assert_false "failed release returns a failure status" failed_release_rolls_back
    assert_eq "$release_test_version" "$(HOME="$TEST_ROOT/release-home" SKM_TESTING=0 "$release_repo/ssh-key-manager" version)" "failed release restores the previous version"
    assert_eq "" "$(git -C "$release_repo" status --short)" "failed release restores a clean worktree"
fi

finish_tests
