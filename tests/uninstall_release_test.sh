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
    cp -R "$ROOT" "$release_repo"
    git -C "$release_repo" config user.name "SKM Tests"
    git -C "$release_repo" config user.email "skm-tests@example.invalid"
    git -C "$release_repo" add -A
    git -C "$release_repo" commit -m "test: release fixture" >/dev/null
    SKM_RELEASE_TEST_CHILD=1 bash "$release_repo/release.sh" 1.0.1 >/dev/null
    assert_eq "1.0.1" "$(HOME="$TEST_ROOT/release-home" SKM_TESTING=0 "$release_repo/ssh-key-manager" version)" "release rebuilds the bundled executable"
    assert_true "release updates installer version" grep -q '^VERSION="1.0.1"$' "$release_repo/install.sh"
    assert_true "release updates source version" grep -q '^VERSION="1.0.1"$' "$release_repo/src/runtime.sh"
    assert_true "release creates the annotated tag" bash -c "git -C '$release_repo' rev-parse -q --verify refs/tags/v1.0.1 >/dev/null"
    assert_eq "" "$(git -C "$release_repo" status --short)" "release leaves a clean worktree"
fi

finish_tests
