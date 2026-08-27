#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime

# shellcheck disable=SC2034
SKM_TEST_LATEST_VERSION="99.0.0"
check_for_updates true
assert_eq "99.0.0" "$LATEST_VERSION" "release update checks parse a newer version"
assert_eq "1" "$UPDATE_AVAILABLE" "newer releases set the update badge"
assert_true "semantic version comparison accepts newer minor versions" version_is_newer "1.1.0" "1.0.9"
assert_false "semantic version comparison rejects older versions" version_is_newer "0.9.9" "1.0.0"
unset SKM_TEST_LATEST_VERSION

original_path="$PATH"
install_fake_bin="$TEST_ROOT/install-fake-bin"
install_prefix="$TEST_ROOT/installed/bin"
mkdir -p "$install_fake_bin"
cat > "$install_fake_bin/curl" <<'EOF'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then shift; output="$1"; fi
  case "$1" in https://*) url="$1" ;; esac
  shift
done
source_file="${UPDATE_SOURCE:-$INSTALL_SOURCE}"
if [ "${FAIL_RELEASE_ASSETS:-0}" = "1" ]; then
  case "$url" in *"/releases/download/"*) exit 22 ;; esac
fi
case "$url" in
  *.sha256)
    if [ "${BAD_CHECKSUM:-0}" = "1" ]; then
      printf '%064d  ssh-key-manager\n' 0 > "$output"
    elif command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$source_file" | awk '{print $1 "  ssh-key-manager"}' > "$output"
    else
      shasum -a 256 "$source_file" | awk '{print $1 "  ssh-key-manager"}' > "$output"
    fi
    ;;
  *) cp "$source_file" "$output" ;;
esac
EOF
chmod 755 "$install_fake_bin/curl"
INSTALL_SOURCE="$ROOT/ssh-key-manager" PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/installer-home" \
    bash -u -s -- --prefix "$install_prefix" < "$ROOT/install.sh" >/dev/null
assert_eq "$VERSION" "$(HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 "$install_prefix/skm" version)" "piped installer works with nounset enabled"

missing_release_prefix="$TEST_ROOT/missing-release/bin"
missing_release_install_fails() {
    INSTALL_SOURCE="$ROOT/ssh-key-manager" FAIL_RELEASE_ASSETS=1 PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/missing-release-home" \
        bash -u -s -- --prefix "$missing_release_prefix" < "$ROOT/install.sh" >/dev/null 2>&1
}
assert_false "installer fails closed when versioned release assets are unavailable" missing_release_install_fails
assert_false "missing release assets never fall back to a moving branch" test -e "$missing_release_prefix/ssh-key-manager"

wrong_version_source="$TEST_ROOT/ssh-key-manager-wrong-version"
sed 's/^VERSION="[^"]*"/VERSION="9.9.8"/' "$ROOT/ssh-key-manager" > "$wrong_version_source"
chmod 755 "$wrong_version_source"
wrong_version_prefix="$TEST_ROOT/wrong-version/bin"
wrong_version_install_fails() {
    INSTALL_SOURCE="$wrong_version_source" PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/wrong-version-home" \
        bash -u -s -- --prefix "$wrong_version_prefix" < "$ROOT/install.sh" >/dev/null 2>&1
}
assert_false "installer rejects a checksummed artifact whose embedded version is unexpected" wrong_version_install_fails
assert_false "version mismatch writes no executable" test -e "$wrong_version_prefix/ssh-key-manager"

bad_install_prefix="$TEST_ROOT/bad-install/bin"
bad_checksum_install_fails() {
    INSTALL_SOURCE="$ROOT/ssh-key-manager" BAD_CHECKSUM=1 PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/bad-installer-home" \
        bash -u -s -- --prefix "$bad_install_prefix" < "$ROOT/install.sh" >/dev/null 2>&1
}
assert_false "remote installer rejects a checksum mismatch" bad_checksum_install_fails
assert_false "failed installer checksum writes no executable" test -e "$bad_install_prefix/ssh-key-manager"

update_source="$TEST_ROOT/ssh-key-manager-9.9.9"
sed 's/^VERSION="[^"]*"/VERSION="9.9.9"/' "$ROOT/ssh-key-manager" > "$update_source"
chmod 755 "$update_source"
INSTALL_SOURCE="$ROOT/ssh-key-manager" UPDATE_SOURCE="$update_source" SKM_TEST_LATEST_VERSION="9.9.9" \
    PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 \
    "$install_prefix/skm" update install >/dev/null
assert_eq "9.9.9" "$(HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 "$install_prefix/skm" version)" "self-update atomically installs a validated release"
assert_true "self-update keeps a rollback copy" test -f "$install_prefix/ssh-key-manager.previous"

bad_update_source="$TEST_ROOT/ssh-key-manager-9.9.10"
sed 's/^VERSION="[^"]*"/VERSION="9.9.10"/' "$ROOT/ssh-key-manager" > "$bad_update_source"
chmod 755 "$bad_update_source"
bad_checksum_update_fails() {
    INSTALL_SOURCE="$ROOT/ssh-key-manager" UPDATE_SOURCE="$bad_update_source" BAD_CHECKSUM=1 SKM_TEST_LATEST_VERSION="9.9.10" \
        PATH="$install_fake_bin:$original_path" HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 \
        "$install_prefix/skm" update install >/dev/null 2>&1
}
assert_false "self-update rejects a checksum mismatch" bad_checksum_update_fails
assert_eq "9.9.9" "$(HOME="$TEST_ROOT/installer-home" SKM_TESTING=0 "$install_prefix/skm" version)" "failed checksum leaves the installed version unchanged"

finish_tests
