from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected replacement target once, found {count}")
    p.write_text(text.replace(old, new, 1))


# Include nested integration tests in syntax/ShellCheck coverage.
replace_once(
    "Makefile",
    "TEST_SOURCES := tests/test.sh tests/helpers/test_helper.sh $(wildcard tests/*_test.sh)\n",
    "TEST_SOURCES := tests/test.sh tests/helpers/test_helper.sh $(wildcard tests/*_test.sh) $(wildcard tests/integration/*.sh)\n",
)
replace_once(
    "build/lint.sh",
    '''for path in "$ROOT"/tests/*_test.sh; do
    targets+=("$path")
done

shellcheck "${targets[@]}"
''',
    '''for path in "$ROOT"/tests/*_test.sh; do
    targets+=("$path")
done
if [[ -d "$ROOT/tests/integration" ]]; then
    for path in "$ROOT"/tests/integration/*.sh; do
        [[ -e "$path" ]] && targets+=("$path")
    done
fi

shellcheck "${targets[@]}"
''',
)

# Make the real sshd test self-contained on Ubuntu runners.
replace_once(
    "tests/integration/sshd_integration_test.sh",
    '''cat > "$tmp/sshd_config" <<EOF
''',
    '''sudo mkdir -p /run/sshd

cat > "$tmp/sshd_config" <<EOF
''',
)
replace_once(
    "tests/integration/sshd_integration_test.sh",
    '''for _ in $(seq 1 30); do
''',
    '''for _ in {1..30}; do
''',
)

# Prove backup retention rather than only implementing it.
replace_once(
    "tests/fleet_test.sh",
    '''identity_activate phone >/dev/null

finish_tests
''',
    '''identity_activate phone >/dev/null

retention_base="$TEST_ROOT/retention"
for n in 1 2 3 4; do
    : > "$retention_base.pre-test-$n"
    sleep 1
 done
prune_backups "$retention_base" 2
retention_count=$(find "$TEST_ROOT" -maxdepth 1 -type f -name 'retention.pre-*' | wc -l | tr -d '[:space:]')
assert_eq "2" "$retention_count" "backup retention keeps only the configured newest backups"

finish_tests
''',
)

# Bump release version in source and installer; generated bundle is produced by the workflow.
replace_once("src/runtime.sh", 'VERSION="1.4.0"\n', 'VERSION="1.5.0"\n')
replace_once("install.sh", 'VERSION="1.4.0"\n', 'VERSION="1.5.0"\n')

# README: surface v1.5 trust/security behavior without bloating the quick start.
replace_once(
    "README.md",
    '''policy, trust auditing, configuration backup/restore, fleet identity sync, and
JSON output for automation.
''',
    '''policy, SSH host-key pinning, trust auditing, configuration backup/restore,
fleet identity sync, and structured JSON output for automation.
''',
)
replace_once(
    "README.md",
    '''| Desired state | Where should that identity be authorized? | `skm policy ...` |
| Audit | Is observed trust clean and consistent? | `skm audit` |
''',
    '''| Desired state | Where should that identity be authorized? | `skm policy ...` |
| Host trust | Is this SSH server still the one I pinned? | `skm host trust/verify ...` |
| Audit | Is observed trust clean and consistent? | `skm audit` |
''',
)
replace_once(
    "README.md",
    '''- remote mutations use fixed embedded scripts rather than user-controlled shell commands;
- public-key payloads travel over standard input instead of shell interpolation;
''',
    '''- remote mutations use fixed embedded scripts rather than user-controlled shell commands;
- when the SKM management key exists, SSH uses it with `IdentitiesOnly=yes` so agent/default keys cannot silently satisfy management access;
- remote host keys can be pinned in SKM's private `known_hosts`; pinned hosts force strict host-key verification;
- public-key payloads travel over standard input instead of shell interpolation;
''',
)
replace_once(
    "README.md",
    '''- there is no telemetry and updates are never installed silently;
- update downloads are versioned, SHA-256 verified, syntax checked, and replaced atomically.
''',
    '''- there is no telemetry and updates are never installed silently;
- versioned release assets fail closed if unavailable; the installer never falls back to a moving branch;
- update downloads are SHA-256/version/syntax verified and replaced atomically;
- releases publish a source-commit manifest and GitHub build-provenance attestation for independent verification.
''',
)
replace_once(
    "README.md",
    '''skm host add rpi5 root 192.168.1.20 22
skm host test rpi5
```

### 2. Give this machine access
''',
    '''skm host add rpi5 root 192.168.1.20 22
skm host test rpi5
```

For stronger server identity assurance, inspect the presented host-key fingerprints,
verify the expected fingerprint through an independent channel, then pin it:

```bash
skm host fingerprint rpi5
skm host trust rpi5 'SHA256:...'
skm host verify rpi5
```

`ssh-keyscan` discovers keys; it does not authenticate them by itself. See
[SSH host trust](docs/host-trust.md).

### 2. Give this machine access
''',
)
replace_once(
    "README.md",
    '''```bash
skm sync identities "Mac Mini"
```

This replaces the remote SKM identity registry using the existing management SSH
path. The remote registry is validated, backed up, and written with mode `0600`.
''',
    '''```bash
skm sync identities "Mac Mini" --dry-run
skm sync identities "Mac Mini"
```

The dry run shows `ADD`, `UPDATE`, `REMOVE`, and `UNCHANGED` entries. Before any
replacement, SKM reads the remote registry and policy and refuses a sync that
would orphan a remote policy rule. Successful replacement is validated, backed
up, and written with mode `0600`.
''',
)
replace_once(
    "README.md",
    '''{"command":"audit","version":"1.4.0","ok":true,"exit_code":0,"issue_count":0,"issues":[]}
''',
    '''{"command":"audit","version":"1.5.0","ok":true,"exit_code":0,"issue_count":0,"issues":[],"findings":[]}
''',
)
replace_once(
    "README.md",
    '''# Machines
skm host list
skm host add NAME USER HOST [PORT]
skm host remove NAME
skm host test NAME
''',
    '''# Machines / SSH host trust
skm host list
skm host show NAME
skm host add NAME USER HOST [PORT]
skm host edit NAME USER HOST [PORT]
skm host rename NAME NEW_NAME
skm host remove NAME [--force]
skm host test NAME
skm host fingerprint NAME
skm host trust NAME [FINGERPRINT]
skm host verify NAME
skm host untrust NAME
''',
)
replace_once(
    "README.md",
    '''skm config import PATH|-
skm sync identities MACHINE
''',
    '''skm config import PATH|-
skm sync identities MACHINE [--dry-run]
''',
)
replace_once(
    "README.md",
    '''| `~/.config/ssh-key-manager/config` | Allow-listed application settings |
| `~/.config/ssh-key-manager/update.state` | Cached release-check state |
''',
    '''| `~/.config/ssh-key-manager/config` | Allow-listed application settings |
| `~/.config/ssh-key-manager/known_hosts` | SKM-managed pinned SSH host keys (`0600`) |
| `~/.config/ssh-key-manager/update.state` | Cached release-check state |
''',
)
replace_once(
    "README.md",
    '''New hosts default to:

```text
StrictHostKeyChecking=accept-new
```

This rejects changed host keys but trusts a first-seen key. Environments with
pre-provisioned `known_hosts` can set:

```text
STRICT_HOST_KEY_CHECKING="yes"
```
''',
    '''Unpinned hosts default to OpenSSH `StrictHostKeyChecking=accept-new`: a
changed key is rejected, but a first-seen key is trusted. For security-sensitive
hosts, prefer an explicit SKM pin after independently verifying the fingerprint.
Once pinned, SKM uses its own `known_hosts`, forces `StrictHostKeyChecking=yes`,
and disables global known-host fallback for that connection.
''',
)
replace_once(
    "README.md",
    '''The updater downloads the versioned release executable and checksum over HTTPS,
verifies SHA-256, confirms the embedded version/shebang, runs `bash -n`, keeps
the previous binary as `.previous`, and replaces the executable atomically.
''',
    '''The updater downloads only versioned release assets over HTTPS. Missing assets
fail closed rather than falling back to `main`. SKM verifies SHA-256, embedded
version/shebang, and `bash -n`, keeps the previous binary as `.previous`, and
replaces the executable atomically.

Each release also publishes `release-manifest.txt` with the source commit and a
GitHub build-provenance attestation. With GitHub CLI installed, a downloaded
release artifact can be independently checked with:

```bash
gh attestation verify ssh-key-manager --repo SwiftExplorer567/ssh-key-manager
```
''',
)
replace_once(
    "README.md",
    '''| `src/hosts.sh` | Machine persistence and host operations |
| `src/ssh_transport.sh` | SSH transport primitives |
''',
    '''| `src/hosts.sh` | Machine persistence and host operations |
| `src/host_trust.sh` | SSH host-key discovery, pinning, and verification |
| `src/ssh_transport.sh` | SSH transport primitives and managed-identity enforcement |
''',
)
replace_once(
    "README.md",
    '''CI validates the generated artifact, functional tests, Bash syntax, and
ShellCheck on Ubuntu and macOS. Commit messages follow Conventional Commits.
''',
    '''CI validates the generated artifact, functional tests, Bash syntax, and
ShellCheck on Ubuntu and macOS. Ubuntu also starts a real isolated OpenSSH daemon
to prove that SKM cannot authenticate through an unrelated ssh-agent identity.
Commit messages follow Conventional Commits.
''',
)
replace_once(
    "README.md",
    '''The release workflow reruns the full verification suite, creates an annotated
tag, and publishes the executable plus SHA-256 checksum.
''',
    '''The release workflow reruns the full verification suite, creates an annotated
tag, and publishes the executable, SHA-256 checksum, source-commit manifest, and
GitHub build-provenance attestation.
''',
)
replace_once(
    "README.md",
    '''- [Fleet configuration & automation](docs/fleet-automation.md)
- [v1.2 migration notes](docs/migration-v1.2.md)
''',
    '''- [Fleet configuration & automation](docs/fleet-automation.md)
- [SSH host trust](docs/host-trust.md)
- [v1.5.0 security hardening notes](docs/v1.5.0.md)
- [v1.2 migration notes](docs/migration-v1.2.md)
''',
)

# Fleet docs: add v1.5 preflight/structured findings/retention semantics.
replace_once(
    "docs/fleet-automation.md",
    '''SSH Key Manager 1.4 adds safe configuration portability and script-friendly
trust checks on top of the v1.2 identity registry and v1.3 desired-state policy.
''',
    '''SSH Key Manager 1.4 introduced safe configuration portability and script-friendly
trust checks. Version 1.5 hardens that model with sync planning, remote-policy
preflight, bounded backup retention, and structured finding codes.
''',
)
replace_once(
    "docs/fleet-automation.md",
    '''For nodes that should share the same canonical fingerprint registry:

```bash
skm sync identities "Mac Mini"
```

The command:

1. validates and serializes the current identity registry;
2. connects to the saved remote machine using SKM's existing management SSH key;
3. validates the payload again on the remote machine;
4. backs up the remote identity registry;
5. atomically replaces the remote registry with mode `0600`.

An empty local registry is never pushed. Symlinked remote registries are refused.
Policy is intentionally left untouched.
''',
    '''For nodes that should share the same canonical fingerprint registry, plan first:

```bash
skm sync identities "Mac Mini" --dry-run
skm sync identities "Mac Mini"
```

The command:

1. validates and serializes the current identity registry;
2. connects using the saved management path and `IdentitiesOnly=yes` when the managed key exists;
3. reads and validates the remote identity registry and desired-state policy;
4. prints `ADD`, `UPDATE`, `REMOVE`, and `UNCHANGED` changes;
5. refuses the apply if the incoming registry would orphan or retire an identity still referenced by remote policy;
6. backs up the remote identity registry and atomically replaces it with mode `0600`.

An empty local registry is never pushed. Symlinked remote registries are refused.
Policy is intentionally left untouched. Timestamped metadata backups retain the
newest five copies by default; `SKM_BACKUP_RETENTION` can change that local limit.
''',
)
replace_once(
    "docs/fleet-automation.md",
    '''{"command":"policy-check","version":"1.4.0","ok":true,"exit_code":0,"issue_count":0,"issues":[]}
''',
    '''{"command":"policy-check","version":"1.5.0","ok":true,"exit_code":0,"issue_count":0,"issues":[],"findings":[]}
''',
)
replace_once(
    "docs/fleet-automation.md",
    '''{"command":"policy-check","version":"1.4.0","ok":false,"exit_code":1,"issue_count":2,"issues":["MISSING phone -> server-b","EXCESS phone -> server-a"]}
''',
    '''{"command":"policy-check","version":"1.5.0","ok":false,"exit_code":1,"issue_count":2,"issues":["MISSING phone -> server-b","EXCESS phone -> server-a"],"findings":[{"code":"POLICY_MISSING","severity":"warning","message":"MISSING phone -> server-b"},{"code":"POLICY_EXCESS","severity":"warning","message":"EXCESS phone -> server-a"}]}
''',
)
replace_once(
    "docs/fleet-automation.md",
    '''These commands are suitable for cron, systemd timers, CI jobs, monitoring hooks,
or other automation that needs a stable success/failure signal without parsing
the human table output.
''',
    '''The legacy `issues` strings remain for compatibility, while `findings` adds
stable machine-readable codes such as `POLICY_MISSING` and `POLICY_EXCESS`.
These commands are suitable for cron, systemd timers, CI jobs, monitoring hooks,
or other automation without parsing human terminal output.
''',
)

# Security policy reflects the new boundaries.
replace_once(
    "SECURITY.md",
    '''- SSH argument construction and host validation;
- symlink and file-permission handling;
''',
    '''- SSH argument construction, managed-identity enforcement, and host-key validation;
- symlink and file-permission handling;
''',
)
replace_once(
    "SECURITY.md",
    '''- updater checksum/version verification;
- terminal rendering of attacker-controlled key comments;
''',
    '''- updater checksum/version verification and release provenance;
- terminal rendering of attacker-controlled key comments;
''',
)
replace_once(
    "SECURITY.md",
    '''- imported trust metadata is validated before mutation;
- updates are explicit and checksum verified;
- audit findings are read-only and never trigger automatic revocation.
''',
    '''- imported trust metadata is validated before mutation;
- an existing SKM management key is the only identity offered by SKM transport;
- SSH host keys can be explicitly pinned and verified in an SKM-owned trust store;
- updates are explicit, version-pinned, fail closed, checksum verified, and published with provenance metadata;
- audit findings are read-only and never trigger automatic revocation.
''',
)

Path("docs/host-trust.md").write_text('''# SSH host trust\n\nSSH public-key authorization answers **who may enter a server**. SSH host-key\nverification answers the opposite question: **which server did the client reach**.\nVersion 1.5 gives SSH Key Manager an explicit, local host-key trust store so a\nmanagement connection can enforce both sides of that relationship.\n\n## Discover, verify, then pin\n\n```bash\nskm host fingerprint server-a\n```\n\nThis uses `ssh-keyscan` against the saved host and port and displays SHA-256 host\nkey fingerprints. Discovery is not authentication: when host identity matters,\ncompare the fingerprint with a value obtained independently from the server, its\nconsole, an administrator, or another trusted channel.\n\nAfter verification, pin the exact fingerprint:\n\n```bash\nskm host trust server-a 'SHA256:...'\nskm host verify server-a\n```\n\nPassing an expected fingerprint is non-interactive and fails if the server does\nnot currently present that key. Running `skm host trust server-a` without a\nfingerprint displays the scan and asks for confirmation before storing it.\n\n## What changes after pinning\n\nSKM stores pins in:\n\n```text\n~/.config/ssh-key-manager/known_hosts\n```\n\nThe file is local metadata with mode `0600`. For a pinned host, SKM forces:\n\n```text\nStrictHostKeyChecking=yes\nUserKnownHostsFile=<SKM known_hosts>\nGlobalKnownHostsFile=/dev/null\n```\n\nThat means a global user/system known-host entry cannot silently override the\nSKM pin for that management connection. If an SKM managed identity exists, the\nsame connection also uses `IdentitiesOnly=yes`.\n\n## Verify or remove a pin\n\n```bash\nskm host verify server-a\nskm host untrust server-a\n```\n\n`verify` rescans the saved endpoint and succeeds only if a pinned key is still\npresented. `untrust` removes only the SKM pin; it does not edit system/global\n`known_hosts` files or SSH authorization.\n\n## Unpinned hosts\n\nFor backwards compatibility, unpinned hosts continue to use the configured\n`STRICT_HOST_KEY_CHECKING` mode, which defaults to `accept-new`. That mode\nrejects changed host keys but trusts a first-seen key. Explicit pinning is the\nrecommended mode for important servers.\n''')

Path("docs/v1.5.0.md").write_text('''# SSH Key Manager v1.5.0\n\nVersion 1.5 is a security-hardening release focused on SSH transport correctness,\nhost identity, safe fleet operations, and release provenance.\n\n## Highlights\n\n- remote installs are version-pinned and fail closed when release assets are unavailable;\n- downloaded artifacts must match the expected embedded version in addition to SHA-256;\n- SKM transport uses `IdentitiesOnly=yes` whenever the managed key exists;\n- `skm host fingerprint/trust/verify/untrust` adds explicit SSH host-key pinning;\n- `host show/edit/rename/remove --force` makes machine lifecycle policy-aware;\n- only one saved alias may represent the local SKM node;\n- `skm sync identities MACHINE --dry-run` previews registry changes;\n- sync preflight refuses to invalidate the remote node's desired-state policy;\n- timestamped metadata backups have bounded retention (five by default);\n- audit/policy JSON includes stable structured `findings` while retaining `issues`;\n- local managed-key paths/symlinks and generated key comments receive stricter validation;\n- `skm doctor` now reports broader trust/filesystem/host-pin health;\n- CI includes a real OpenSSH daemon test proving agent keys cannot bypass the managed identity;\n- releases include a source-commit manifest and GitHub build-provenance attestation.\n\n## Upgrade notes\n\nNo registry or policy migration is required from v1.4. Existing remote hosts remain\nunpinned until you explicitly trust them, so upgrading does not replace your\ncurrent host-key behavior automatically.\n\nThe intentional behavior change is management identity selection: if a host was\nreachable only because ssh-agent or a default SSH key happened to authenticate,\n`skm host test` may now fail once an SKM managed key exists. That is correct: grant\nthe SKM managed public key explicitly rather than relying on an unrelated identity.\n\nRecommended post-upgrade checks:\n\n```bash\nskm doctor\nskm policy check\nskm audit\nskm sync identities REMOTE --dry-run\n```\n\nFor important hosts, independently verify the server fingerprint before pinning:\n\n```bash\nskm host fingerprint REMOTE\nskm host trust REMOTE 'SHA256:...'\nskm host verify REMOTE\n```\n''')
