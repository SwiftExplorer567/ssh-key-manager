from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected patch anchor missing in {path}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace("src/runtime.sh", 'VERSION="1.3.0"', 'VERSION="1.4.0"')
replace("install.sh", 'VERSION="1.3.0"', 'VERSION="1.4.0"')

replace(
    "build/bundle.sh",
    '    printf \'REMOTE_REMOVE_SCRIPT=%q\\n\' "$(<"$ROOT/remote/authorized_remove.sh")"\n',
    '    printf \'REMOTE_REMOVE_SCRIPT=%q\\n\' "$(<"$ROOT/remote/authorized_remove.sh")"\n'
    '    printf \'REMOTE_IDENTITIES_SYNC_SCRIPT=%q\\n\' "$(<"$ROOT/remote/identities_replace.sh")"\n',
)
replace(
    "build/bundle.sh",
    '    append_module "$ROOT/src/security_display.sh"\n    append_module "$ROOT/src/updates.sh"\n',
    '    append_module "$ROOT/src/security_display.sh"\n    append_module "$ROOT/src/fleet.sh"\n    append_module "$ROOT/src/updates.sh"\n',
)

replace(
    "build/lint.sh",
    '    printf \'REMOTE_REMOVE_SCRIPT=""\\n\'\n',
    '    printf \'REMOTE_REMOVE_SCRIPT=""\\n\'\n    printf \'REMOTE_IDENTITIES_SYNC_SCRIPT=""\\n\'\n',
)
replace(
    "build/lint.sh",
    '    append_module "$ROOT/src/security_display.sh"\n    append_module "$ROOT/src/updates.sh"\n',
    '    append_module "$ROOT/src/security_display.sh"\n    append_module "$ROOT/src/fleet.sh"\n    append_module "$ROOT/src/updates.sh"\n',
)
replace(
    "build/lint.sh",
    '    "$ROOT/remote/authorized_remove.sh"\n',
    '    "$ROOT/remote/authorized_remove.sh"\n    "$ROOT/remote/identities_replace.sh"\n',
)

replace(
    "tests/test.sh",
    '    policy_test.sh\n    updates_install_test.sh\n',
    '    policy_test.sh\n    fleet_test.sh\n    updates_install_test.sh\n',
)

replace(
    "src/cli.sh",
    '  skm policy check                   Exit nonzero on MISSING/EXCESS policy drift\n'
    '  skm key list                      Public key inventory for all machines\n',
    '  skm policy check [--json]          Exit nonzero on MISSING/EXCESS policy drift\n'
    '  skm config export [PATH|-]         Export registry + policy (no private keys)\n'
    '  skm config validate PATH|-         Validate a trust config before import\n'
    '  skm config import PATH|-           Restore registry + policy with backups\n'
    '  skm sync identities MACHINE       Replace a remote canonical identity registry\n'
    '  skm key list                      Public key inventory for all machines\n',
)
replace(
    "src/cli.sh",
    '  skm audit                         Audit trust, unknown/retired keys and hygiene\n',
    '  skm audit [--json]                Audit trust; JSON mode preserves exit status\n',
)
replace(
    "src/cli.sh",
    '                check) policy_check;;\n'
    '                *) die "Usage: skm policy {list|expect|remove|matrix|check}";;\n',
    '                check)\n'
    '                    if [[ "${2:-}" == "--json" ]]; then policy_check_json\n'
    '                    elif [[ -z "${2:-}" ]]; then policy_check\n'
    '                    else die "Usage: skm policy check [--json]"\n'
    '                    fi\n'
    '                    ;;\n'
    '                *) die "Usage: skm policy {list|expect|remove|matrix|check}";;\n',
)
replace(
    "src/cli.sh",
    '            ;;\n        key)\n',
    '            ;;\n'
    '        config)\n'
    '            shift\n'
    '            case "${1:-}" in\n'
    '                export) config_export "${2:--}";;\n'
    '                validate) [[ -n "${2:-}" ]] || die "Usage: skm config validate PATH|-"; config_validate "$2";;\n'
    '                import) [[ -n "${2:-}" ]] || die "Usage: skm config import PATH|-"; config_import "$2";;\n'
    '                *) die "Usage: skm config {export|validate|import}";;\n'
    '            esac\n'
    '            ;;\n'
    '        sync)\n'
    '            shift\n'
    '            case "${1:-}" in\n'
    '                identities) [[ -n "${2:-}" ]] || die "Usage: skm sync identities MACHINE"; sync_identities "$2";;\n'
    '                *) die "Usage: skm sync identities MACHINE";;\n'
    '            esac\n'
    '            ;;\n'
    '        key)\n',
)
replace(
    "src/cli.sh",
    '        audit) audit ;;\n',
    '        audit)\n'
    '            if [[ "${2:-}" == "--json" ]]; then audit_json\n'
    '            elif [[ -z "${2:-}" ]]; then audit\n'
    '            else die "Usage: skm audit [--json]"\n'
    '            fi\n'
    '            ;;\n',
)

replace(
    "src/fleet.sh",
    '    local operation="$1" source="$2" path="$source" tmp="" rc\n',
    '    local operation="$1" source="$2" tmp="" rc\n    local path="$source"\n',
)
replace(
    "tests/fleet_test.sh",
    'assert_true "import creates identity backup" bash -c \'compgen -G "$1.pre-import-*" >/dev/null\' _ "$SKM_IDENTITIES_FILE"\n'
    'assert_true "import creates policy backup" bash -c \'compgen -G "$1.pre-import-*" >/dev/null\' _ "$SKM_POLICY_FILE"\n',
    'backup_exists() { compgen -G "$1" >/dev/null; }\n'
    'assert_true "import creates identity backup" backup_exists "$SKM_IDENTITIES_FILE.pre-import-*"\n'
    'assert_true "import creates policy backup" backup_exists "$SKM_POLICY_FILE.pre-import-*"\n',
)
replace(
    "remote/identities_replace.sh",
    '$2 !~ /^SHA256:[A-Za-z0-9+\\/=_.-]+$/ { exit 1 }',
    '$2 !~ /^SHA256:[A-Za-z0-9+\\/=_-]+$/ { exit 1 }',
)
