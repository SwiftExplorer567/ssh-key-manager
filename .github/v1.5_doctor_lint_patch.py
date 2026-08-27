from pathlib import Path

p = Path('src/access.sh')
s = p.read_text()
old = '''    command -v ssh >/dev/null 2>&1 && ok "OpenSSH client: available" || { fail "OpenSSH client is missing."; issues=$((issues+1)); }
    command -v ssh-keygen >/dev/null 2>&1 && ok "ssh-keygen: available" || { fail "ssh-keygen is missing."; issues=$((issues+1)); }
    command -v curl >/dev/null 2>&1 && ok "curl: available for updates" || info "curl is unavailable; remote update checks/install will not work."
'''
new = '''    if command -v ssh >/dev/null 2>&1; then
        ok "OpenSSH client: available"
    else
        fail "OpenSSH client is missing."
        issues=$((issues + 1))
    fi
    if command -v ssh-keygen >/dev/null 2>&1; then
        ok "ssh-keygen: available"
    else
        fail "ssh-keygen is missing."
        issues=$((issues + 1))
    fi
    if command -v curl >/dev/null 2>&1; then
        ok "curl: available for updates"
    else
        info "curl is unavailable; remote update checks/install will not work."
    fi
'''
if s.count(old) != 1:
    raise SystemExit(f'doctor command check block count={s.count(old)}')
p.write_text(s.replace(old, new))

p = Path('tests/access_test.sh')
s = p.read_text()
old = '# shellcheck disable=SC1090,SC1091\n'
new = '# shellcheck disable=SC1090,SC1091,SC2034 # sourced SKM functions consume global MANAGED_KEY\n'
if s.count(old) != 1:
    raise SystemExit('access test shellcheck directive not found exactly once')
p.write_text(s.replace(old, new))
