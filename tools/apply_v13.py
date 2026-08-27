from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected block not found in {path}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


replace_once('src/runtime.sh', 'VERSION="1.2.0"', 'VERSION="1.3.0"')
replace_once(
    'src/runtime.sh',
    'IDENTITIES_FILE="${SKM_IDENTITIES_FILE:-$CONFIG_DIR/identities.conf}"\n',
    'IDENTITIES_FILE="${SKM_IDENTITIES_FILE:-$CONFIG_DIR/identities.conf}"\n'
    'POLICY_FILE="${SKM_POLICY_FILE:-$CONFIG_DIR/policy.conf}"\n',
)
replace_once(
    'src/runtime.sh',
    '    [[ -e "$IDENTITIES_FILE" ]] || : > "$IDENTITIES_FILE"\n'
    '    chmod 600 "$HOSTS_FILE" "$IDENTITIES_FILE" 2>/dev/null || true\n',
    '    [[ -e "$IDENTITIES_FILE" ]] || : > "$IDENTITIES_FILE"\n'
    '    [[ -e "$POLICY_FILE" ]] || : > "$POLICY_FILE"\n'
    '    chmod 600 "$HOSTS_FILE" "$IDENTITIES_FILE" "$POLICY_FILE" 2>/dev/null || true\n',
)

replace_once('install.sh', 'VERSION="1.2.0"', 'VERSION="1.3.0"')

replace_once(
    'build/bundle.sh',
    '    append_module "$ROOT/src/identities.sh"\n'
    '    append_module "$ROOT/src/security_display.sh"\n',
    '    append_module "$ROOT/src/identities.sh"\n'
    '    append_module "$ROOT/src/policy.sh"\n'
    '    append_module "$ROOT/src/security_display.sh"\n',
)
replace_once(
    'build/lint.sh',
    '    append_module "$ROOT/src/identities.sh"\n'
    '    append_module "$ROOT/src/security_display.sh"\n',
    '    append_module "$ROOT/src/identities.sh"\n'
    '    append_module "$ROOT/src/policy.sh"\n'
    '    append_module "$ROOT/src/security_display.sh"\n',
)

replace_once(
    'tests/helpers/test_helper.sh',
    'export SKM_IDENTITIES_FILE="$SKM_CONFIG_DIR/identities.conf"\n',
    'export SKM_IDENTITIES_FILE="$SKM_CONFIG_DIR/identities.conf"\n'
    'export SKM_POLICY_FILE="$SKM_CONFIG_DIR/policy.conf"\n',
)
replace_once(
    'tests/test.sh',
    '    identity_audit_test.sh\n',
    '    identity_audit_test.sh\n'
    '    policy_test.sh\n',
)

replace_once(
    'src/cli.sh',
    '  skm identity activate NAME\n'
    '  skm key list                      Public key inventory for all machines\n',
    '  skm identity activate NAME\n'
    '  skm policy list\n'
    '  skm policy expect IDENTITY MACHINE  Declare expected authorization\n'
    '  skm policy remove IDENTITY MACHINE  Remove an expectation (does not revoke)\n'
    '  skm policy matrix                  Compare desired and observed authorization\n'
    '  skm policy check                   Exit nonzero on MISSING/EXCESS policy drift\n'
    '  skm key list                      Public key inventory for all machines\n',
)
replace_once(
    'src/cli.sh',
    '                *) die "Usage: skm identity {list|add|show|rename|retire|activate}";;\n'
    '            esac\n'
    '            ;;\n'
    '        key)\n',
    '                *) die "Usage: skm identity {list|add|show|rename|retire|activate}";;\n'
    '            esac\n'
    '            ;;\n'
    '        policy)\n'
    '            shift\n'
    '            case "${1:-}" in\n'
    '                list) policy_list;;\n'
    '                expect) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm policy expect IDENTITY MACHINE"; policy_expect "$2" "$3";;\n'
    '                remove) [[ -n "${2:-}" && -n "${3:-}" ]] || die "Usage: skm policy remove IDENTITY MACHINE"; policy_remove "$2" "$3";;\n'
    '                matrix) policy_matrix;;\n'
    '                check) policy_check;;\n'
    '                *) die "Usage: skm policy {list|expect|remove|matrix|check}";;\n'
    '            esac\n'
    '            ;;\n'
    '        key)\n',
)
replace_once(
    'src/cli.sh',
    '  skm access matrix\n'
    '  skm audit\n',
    '  skm access matrix\n'
    '  skm policy matrix\n'
    '  skm policy check\n'
    '  skm audit\n',
)

replace_once(
    'src/identities.sh',
    '    load_identities\n'
    '    say "SSH trust audit"\n',
    '    load_identities\n'
    '    load_policy\n'
    '    say "SSH trust audit"\n',
)
replace_once(
    'src/identities.sh',
    '    fi\n\n'
    '    label="this machine"\n',
    '    fi\n'
    '    if (( ${#POLICY_FINGERPRINTS[@]} == 0 )); then\n'
    '        info "Desired-state policy is empty; policy drift checks are skipped."\n'
    '    else\n'
    '        ok "Loaded ${#POLICY_FINGERPRINTS[@]} desired access rule(s)."\n'
    '        policy_audit_rules\n'
    '    fi\n\n'
    '    label="this machine"\n',
)
replace_once(
    'src/identities.sh',
    '    audit_authorized_lines "$label" "$auth"\n'
    '    audit_local_key_files\n',
    '    audit_authorized_lines "$label" "$auth"\n'
    '    (( ${#POLICY_FINGERPRINTS[@]} == 0 )) || policy_audit_host "$label" "$auth"\n'
    '    audit_local_key_files\n',
)
replace_once(
    'src/identities.sh',
    '        if auth=$(remote_authorized_keys "$i" 2>/dev/null); then\n'
    '            audit_authorized_lines "${HOST_NAMES[$i]}" "$auth"\n'
    '        else\n',
    '        if auth=$(remote_authorized_keys "$i" 2>/dev/null); then\n'
    '            audit_authorized_lines "${HOST_NAMES[$i]}" "$auth"\n'
    '            (( ${#POLICY_FINGERPRINTS[@]} == 0 )) || policy_audit_host "${HOST_NAMES[$i]}" "$auth"\n'
    '        else\n',
)
