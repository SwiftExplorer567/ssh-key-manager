# shellcheck shell=bash

usage() {
    cat <<'EOF'
SSH Key Manager — public key inventory and access control

Manage the public keys and access grants on your machines. This is a key
management tool; it does not open interactive SSH sessions.

Private keys never move. Each machine owns a dedicated ED25519 key; only public
keys are added to authorized_keys.

Start here:
  skm                              Open the beginner-friendly dashboard

Common tasks:
  1. Add your servers from Machines.
  2. Use Give Access for this device or paste a new client's public key.
  3. Review every reachable machine under Keys & Security > Key inventory.

Commands:
  skm host list
  skm host add NAME USER HOST [PORT]
  skm host remove NAME
  skm host test NAME
  skm access grant NAME [KEY.pub]
  skm access receive NAME
  skm access link NAME [KEY.pub]
  skm access status [NAME]
  skm access revoke NAME           Revoke a key that can enter NAME
  skm access allow [KEY.pub|-]     Allow a public key into this machine
  skm key list                     Public key inventory for all machines
  skm key generate [PATH] [COMMENT]
  skm key public [KEY.pub]
  skm doctor
  skm update check
  skm update install
  skm version

Example — give this device access to a server:
  skm host add storage admin 192.168.1.20
  skm access grant storage

New client with no key:
  Run `skm key public` on the client, then paste the result into the dashboard's
  Give Access > Another device flow. The private key stays on the client.
EOF
}

dispatch() {
    local command="${1:-}"
    case "$command" in
        "") interactive_main ;;
        -h|--help|help) usage ;;
        -V|--version|version) say "$VERSION" ;;
        host)
            shift
            case "${1:-}" in
                list) host_list;;
                add) shift; host_add "${1:-}" "${2:-}" "${3:-}" "${4:-22}";;
                remove) [[ -n "${2:-}" ]] || die "Usage: skm host remove NAME"; host_remove "$2";;
                test) [[ -n "${2:-}" ]] || die "Usage: skm host test NAME"; host_test "$2";;
                *) die "Usage: skm host {list|add|remove|test}";;
            esac
            ;;
        access)
            shift
            case "${1:-}" in
                grant) [[ -n "${2:-}" ]] || die "Usage: skm access grant NAME [KEY.pub]"; access_grant "$2" "${3:-}";;
                receive) [[ -n "${2:-}" ]] || die "Usage: skm access receive NAME"; access_receive "$2";;
                link) [[ -n "${2:-}" ]] || die "Usage: skm access link NAME [KEY.pub]"; access_link "$2" "${3:-}";;
                status) access_status "${2:-}";;
                revoke) [[ -n "${2:-}" ]] || die "Usage: skm access revoke NAME"; access_revoke_remote "$2";;
                allow) access_allow_local "${2:--}";;
                *) die "Usage: skm access {grant|receive|link|status|revoke|allow}";;
            esac
            ;;
        key)
            shift
            case "${1:-}" in
                list) key_list;;
                generate) key_generate "${2:-}" "${3:-}";;
                public) key_public "${2:-}";;
                *) die "Usage: skm key {list|generate|public}";;
            esac
            ;;
        doctor) doctor ;;
        update)
            case "${2:-check}" in
                check)
                    if check_for_updates true; then
                        if (( UPDATE_AVAILABLE == 1 )); then say "Update available: v$VERSION -> v$LATEST_VERSION"; else say "Up to date: v$VERSION"; fi
                    else
                        die "Could not check GitHub releases."
                    fi
                    ;;
                install) install_latest_update;;
                *) die "Usage: skm update {check|install}";;
            esac
            ;;
        give-access|get-access)
            die "'$command' was ambiguous and has been removed. Use 'skm access grant', 'receive', or 'link'; run 'skm help' for directions."
            ;;
        *) die "Unknown command '$command'. Run: skm help";;
    esac
}

if [[ "${SKM_TESTING:-0}" != "1" ]]; then
    ensure_runtime
    load_settings
    load_hosts
    if [[ $# -eq 0 ]]; then check_for_updates false || true; fi
    dispatch "$@"
fi
