#!/usr/bin/env bash

# shellcheck disable=SC1090,SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/test_helper.sh"

ensure_runtime
load_hosts

# These globals are consumed by sourced TUI functions.
# shellcheck disable=SC2034
HOST_NAMES=("Mac Mini" "rpi5")
# shellcheck disable=SC2034
HOST_USERS=("homelab" "root")
# shellcheck disable=SC2034
HOST_ADDRS=("local" "192.168.31.179")
# shellcheck disable=SC2034
HOST_PORTS=("22" "22")
# shellcheck disable=SC2034
HOST_STATUSES=("local" "ready")
local_access_map=$(access_status_one "Mac Mini")
assert_true "access map labels the local host as this machine" grep -Fq '● this machine' <<< "$local_access_map"
assert_false "access map does not show SSH directions for the local host" grep -Fq -- '->' <<< "$local_access_map"
assert_false "access map does not report local self-access as not granted" grep -Fq 'not granted' <<< "$local_access_map"
SKM_FORCE_TUI=1 select_host "Test which machine?" false <<< "2" >/dev/null
assert_eq "rpi5" "$SELECTED_HOST" "TUI host selection returns only the selected name"
assert_eq "1" "$SELECTED_HOST_INDEX" "TUI host selection preserves the selected index"
assert_false "unknown hosts stop instead of falling back to index zero" require_host "missing-host"
assert_eq "-1" "$RESOLVED_HOST_INDEX" "failed host lookup clears the resolved index"
SKM_FORCE_TUI=1 select_host "Remote only" true <<< "1" >/dev/null
assert_eq "rpi5" "$SELECTED_HOST" "remote actions exclude the local machine"
SKM_FORCE_TUI=1 run_menu "Arrow test" "" "One|First" "Two|Second" "Three|Third" <<< $'\e[B\e[B\n' >/dev/null
assert_eq "2" "$MENU_RESULT" "arrow-key navigation selects the highlighted item"
menu_output=$(render_menu "Dashboard" "Simple key management" 0 "Give Access|Authorize a client" "Machines|Manage inventory")
assert_true "polished menu shows numbered primary action" grep -Fq 'Give Access' <<< "$menu_output"
assert_true "polished menu keeps beginner description visible" grep -Fq 'Authorize a client' <<< "$menu_output"

assert_eq "$VERSION" "$(HOME="$HOME" SKM_TESTING=0 NO_COLOR=1 bash "$ROOT/ssh-key-manager" version)" "version command works"
assert_true "help presents SKM as key management" bash -c "HOME='$HOME' SKM_TESTING=0 NO_COLOR=1 bash '$ROOT/ssh-key-manager' help | grep -q 'does not open interactive SSH sessions'"
assert_true "quick connect command is removed" bash -c "HOME='$HOME' SKM_TESTING=0 NO_COLOR=1 bash '$ROOT/ssh-key-manager' connect rpi5 2>&1 | grep -q \"Unknown command 'connect'\""
assert_true "ambiguous legacy wording is rejected" bash -c "HOME='$HOME' SKM_TESTING=0 NO_COLOR=1 bash '$ROOT/ssh-key-manager' give-access 2>&1 | grep -q 'ambiguous'"

finish_tests
