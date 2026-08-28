# RFC-003 — Restricted SSH bridge

Recommended V2 enrollment installs a tiny daemonless bridge and authorizes the dedicated V2 controller key with an OpenSSH forced command plus restrictive key options. The bridge uses stdin/stdout over the existing SSH connection, opens no listening port and never intentionally offers an interactive shell.

## Trust boundary

Enrollment is a separate, explicit operation. V1 migration alone never enables remote mutation. The controller must already possess pinned host trust for the selected Node/Route and connects with `StrictHostKeyChecking=yes`, a controller-owned known-hosts view, `IdentitiesOnly=yes` and the requested bootstrap or V2 management key.

The bootstrap key is used to install or remove the restricted V2 management authorization. After enrollment normal V2 observation and mutation use the separate V2 controller key.

## Protocol v2

The forced-command protocol exposes only:

- `version`
- `inspect`
- `apply EXPECTED_REVISION [MANAGED_FINGERPRINT ...]`
- `rollback EXPECTED_REVISION`

Unsupported commands fail closed. A real-`sshd` integration test proves that the enrolled V2 management key cannot be used to execute an arbitrary requested shell command.

`inspect` returns the current remote revision, protected V2-managed fingerprints and the current `authorized_keys` content. `apply` receives the complete replacement `authorized_keys` content on stdin plus the exact fingerprint set that V2 owns after the operation.

## Ownership model

Trailing `authorized_keys` comments are untrusted metadata and are never used to determine whether SKM owns a key. The bridge keeps managed fingerprints in a separate `0600` sidecar next to `authorized_keys`.

This prevents an external key from becoming revocable merely because somebody edits its comment to resemble an SKM marker. Controller-side revocation refuses a credential unless the bridge reported that fingerprint as managed.

## Mutation safety

Bridge mutation:

1. rejects symlinked `authorized_keys` and managed-state paths;
2. acquires an exclusive bridge lock;
3. compares the current combined revision with the plan's expected revision;
4. stages both authorization and managed-state files at `0600`;
5. re-checks the revision after staging to detect manual edits that do not honor the bridge lock;
6. creates backups of both files;
7. installs the staged files by rename;
8. returns the new revision.

The revision covers both `authorized_keys` and the V2 ownership sidecar. `rollback` is revision-guarded and restores both backup files together.

The bridge is deliberately not a daemon and does not create another remotely reachable service.
