# Contributing

Thanks for helping improve SSH Key Manager (SKM). The project intentionally
keeps a small Bash codebase, a single distributable executable, and explicit
security boundaries.

## Development requirements

- Bash 3.2 or newer
- OpenSSH client tools
- GNU Make
- ShellCheck
- Git

Clone the repository and run the full verification suite:

```bash
git clone https://github.com/SwiftExplorer567/ssh-key-manager.git
cd ssh-key-manager
make ci
```

## Repository structure

- `src/` — application modules;
- `remote/` — fixed remote scripts embedded in the final executable;
- `build/` — bundling and lint helpers;
- `tests/` — isolated functional/regression tests;
- `docs/` — focused design and migration documentation;
- `ssh-key-manager` — generated distributable executable;
- `ssh-key-manager.sha256` — generated checksum.

Do not edit the generated `ssh-key-manager` file by hand. Change the source
modules and run:

```bash
make build
```

CI verifies that generated output is current.

## Pull request workflow

1. Branch from `main`.
2. Keep the change focused.
3. Add or update tests for behavior changes.
4. Run `make ci` locally when possible.
5. Regenerate the bundled executable with `make build` when source changes.
6. Update documentation when behavior or commands change.
7. Open a pull request with the motivation, behavior change, and security impact.

Merged same-repository PR branches are cleaned automatically.

## Commit messages

The repository uses Conventional Commit-style messages. Examples:

```text
feat: add policy drift export
fix: reject malformed remote identity payload
refactor: simplify audit snapshot collection
docs: clarify trust configuration format
test: cover retired identity policy drift
chore: update CI maintenance
```

## Testing

Useful commands:

```bash
make build
make check-generated
make test
make lint
make ci
```

Tests run with isolated temporary HOME/config/SSH directories. New tests must not
read, modify, or depend on the developer's real `~/.ssh` state.

When changing security-sensitive code, include both the expected success path
and relevant rejection/failure cases.

## Compatibility

SKM supports Linux and macOS and intentionally remains compatible with Bash 3.2.
Avoid Bash features introduced after 3.2 unless the compatibility policy is
explicitly changed.

CI runs on Ubuntu and macOS. A change is not ready to merge if either platform
fails.

## Security expectations

Treat these values as untrusted input unless the code has already validated
them:

- public-key comments;
- host names and addresses;
- usernames and ports;
- imported trust config records;
- identity names and fingerprints;
- remote command output.

Do not add code that transfers private keys or places user-controlled values in
remote shell source.

For vulnerabilities, follow [SECURITY.md](SECURITY.md) instead of opening a
public issue.

## Versioning and releases

SKM uses semantic version tags such as `v1.4.0`.

Release publication is automatic after a commit reaches `main` **only when the
embedded source version has been intentionally changed to a version that does
not already have a matching tag**. The release workflow reruns the full CI suite,
creates the annotated tag, and publishes the generated executable and checksum.

Documentation-only and maintenance merges that keep the same version do not
produce a release.

For a release-bearing change, keep the version values in the runtime, installer,
and generated executable consistent and ensure `make ci` passes before merge.

## Pull request checklist

Before requesting review, verify:

- [ ] the change has a clear reason and limited scope;
- [ ] no secrets, private keys, real credentials, or environment-specific trust data are committed;
- [ ] behavior changes have tests;
- [ ] generated files are current;
- [ ] `make ci` passes;
- [ ] Linux/macOS and Bash 3.2 compatibility were considered;
- [ ] user-facing changes are documented;
- [ ] security-sensitive changes explain their trust boundary.
