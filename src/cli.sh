# shellcheck shell=bash

usage() {
    cat <<'EOF'
SSH Key Manager — directional, passwordless SSH access

The rule is simple:
  skm access grant SERVER     This machine -> SERVER
  skm access receive SERVER   SERVER -> this machine
  skm access link SERVER      Both directions

Private keys never move. Each machine owns a dedicated ED25519 key; only public
keys are added to authorized_keys.

Commands:
  skm                              Open the full-screen interactive dashboard
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
  skm connect NAME [SSH_ARGS...]   Quick access
  skm quick NAME [SSH_ARGS...]     Alias for connect
  skm key list
  skm key generate [PATH] [COMMENT]
  skm key public [KEY.pub]
  skm doctor
  skm update check
  skm update install
  skm version

First-time two-server setup:
  skm host add storage admin 192.168.1.20
  skm access link storage

The first command may ask for the remote SSH password once. Afterwards use:
  skm connect storage
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
        connect|quick)
            [[ -n "${2:-}" ]] || die "Usage: skm $command NAME [SSH_ARGS...]"
            shift; local name="$1"; shift; connect_host "$name" "$@"
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
