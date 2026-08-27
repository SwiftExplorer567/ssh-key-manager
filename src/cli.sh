# shellcheck shell=bash

usage() {
    cat <<'EOF'
SSH Key Manager — public key inventory and access control

Manage the public keys and access grants on your machines. This is a key
management tool; it does not open interactive SSH sessions.

Private keys never move. Each machine owns a dedicated ED25519 key; only public
keys are added to authorized_keys. Identity names are local metadata mapped to
immutable SHA256 fingerprints.

Start here:
  skm                              Open the beginner-friendly dashboard

Common tasks:
  1. Add your servers from Machines.
  2. Register known fingerprints with `skm identity add`.
  3. Use Give Access for this device or paste a new client's public key.
  4. Review trust with `skm access matrix` and `skm audit`.

Commands:
  skm host list
  skm host add NAME USER HOST [PORT]
  skm host remove NAME
  skm host test NAME
  skm access grant NAME [KEY.pub]
  skm access receive NAME
  skm access link NAME [KEY.pub]
  skm access status [NAME]
  skm access matrix                 Observed fingerprint authorization matrix
  skm access revoke NAME            Revoke a key that can enter NAME
  skm access allow [KEY.pub|-]      Allow a public key into this machine
  skm identity list
  skm identity add NAME FINGERPRINT [device|server|service|other]
  skm identity show NAME
  skm identity rename NAME NEW_NAME
  skm identity retire NAME
  skm identity activate NAME
  skm policy list
  skm policy expect IDENTITY MACHINE  Declare expected authorization
  skm policy remove IDENTITY MACHINE  Remove an expectation (does not revoke)
  skm policy matrix                  Compare desired and observed authorization
  skm policy check [--json]          Exit nonzero on MISSING/EXCESS policy drift
  skm config export [PATH|-]         Export registry + policy (no private keys)
  skm config validate PATH|-         Validate a trust config before import
  skm config import PATH|-           Restore registry + policy with backups
  skm sync identities MACHINE       Replace a remote canonical identity registry
  skm key list                      Public key inventory for all machines
  skm key generate [PATH] [COMMENT]
  skm key public [KEY.pub]
  skm audit [--json]                Audit trust; JSON mode preserves exit status
  skm doctor
  skm update check
  skm update install
  skm version

Example — register and review a device:
  skm identity add laptop SHA256:abc... device
  skm access matrix
  skm policy matrix
  skm policy check
  skm audit

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
                matrix) access_matrix;;
                revoke) [[ -n "${2:-}" ]] || die "Usage: skm access revoke NAME"; access_revoke_remote "$2";;
                allow) access_allow_local "${2:--}";;
                *) die "Usage: skm access {grant|receive|link|status|matrix|revoke|allow}";;
            esac
            ;;
        identity)
            shift
            case "${1:-}" in
                list) identity_list;;
                add)
                    [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm identity add NAME FINGERPRINT [TYPE]"
                    identity_add "$2" "$3" "${4:-device}"
                    ;;
                show) [[ -n "${2:-}" ]] || die "Usage: skm identity show NAME"; identity_show "$2";;
                rename) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm identity rename NAME NEW_NAME"; identity_rename "$2" "$3";;
                retire) [[ -n "${2:-}" ]] || die "Usage: skm identity retire NAME"; identity_retire "$2";;
                activate) [[ -n "${2:-}" ]] || die "Usage: skm identity activate NAME"; identity_activate "$2";;
                *) die "Usage: skm identity {list|add|show|rename|retire|activate}";;
            esac
            ;;
        policy)
            shift
            case "${1:-}" in
                list) policy_list;;
                expect) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm policy expect IDENTITY MACHINE"; policy_expect "$2" "$3";;
                remove) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm policy remove IDENTITY MACHINE"; policy_remove "$2" "$3";;
                matrix) policy_matrix;;
                check)
                    if [[ "${2:-}" == "--json" ]]; then policy_check_json
                    elif [[ -z "${2:-}" ]]; then policy_check
                    else die "Usage: skm policy check [--json]"
                    fi
                    ;;
                *) die "Usage: skm policy {list|expect|remove|matrix|check}";;
            esac
            ;;
        config)
            shift
            case "${1:-}" in
                export) config_export "${2:--}";;
                validate) [[ -n "${2:-}" ]] || die "Usage: skm config validate PATH|-"; config_validate "$2";;
                import) [[ -n "${2:-}" ]] || die "Usage: skm config import PATH|-"; config_import "$2";;
                *) die "Usage: skm config {export|validate|import}";;
            esac
            ;;
        sync)
            shift
            case "${1:-}" in
                identities) [[ -n "${2:-}" ]] || die "Usage: skm sync identities MACHINE"; sync_identities "$2";;
                *) die "Usage: skm sync identities MACHINE";;
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
        audit)
            if [[ "${2:-}" == "--json" ]]; then audit_json
            elif [[ -z "${2:-}" ]]; then audit
            else die "Usage: skm audit [--json]"
            fi
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
