## Summary

Describe what changes and why.

## Behavior

- What user-visible behavior changes?
- Which commands, files, or trust boundaries are affected?

## Validation

- [ ] `make ci` passes
- [ ] generated `ssh-key-manager` and checksum are current when source changed
- [ ] behavior changes include tests
- [ ] Linux/macOS and Bash 3.2 compatibility were considered
- [ ] documentation was updated when needed

## Security

- [ ] no private keys, credentials, tokens, or environment-specific trust data are committed
- [ ] remote execution / `authorized_keys` / import-export changes were reviewed for validation, symlink, quoting, and permission safety
- [ ] attacker-controlled key comments or remote output are treated as untrusted metadata

## Release

- [ ] this PR intentionally changes the embedded version if it should publish a new release
- [ ] this PR keeps the current version if it should not create a release
