# Fleet configuration and automation

SSH Key Manager 1.4 introduced safe configuration portability and script-friendly
trust checks. Version 1.5 hardens that model with sync planning, remote-policy
preflight, bounded backup retention, and structured finding codes.

## Design boundary

V1.4 treats two kinds of metadata differently:

- **identity registry** — fingerprint-anchored and portable between SKM nodes;
- **desired-state policy** — fingerprint-anchored, but its machine names are local
  SKM aliases and may differ from one management node to another.

Because of that distinction, `skm sync identities` may replace a remote identity
registry, but it never mirrors policy automatically. This prevents a policy made
on a node with machine names such as `raspberrypi` and `Mac Mini` from silently
becoming stale on another node that calls the same machines `rpi5` and
`Mac Mini`.

No V1.4 configuration command copies private SSH keys or edits
`authorized_keys`.

## Trust configuration export

Export the identity registry and desired-state policy to a versioned text bundle:

```bash
skm config export trust-config.skm
```

Write the bundle to stdout instead:

```bash
skm config export -
```

The file format is intentionally simple and non-executable:

```text
SKM-TRUST-CONFIG|1
IDENTITY|NAME|SHA256:FINGERPRINT|TYPE|STATUS
POLICY|SHA256:FINGERPRINT|MACHINE_NAME
```

Exports are written with mode `0600` when a destination file is used. The bundle
contains no private keys, `authorized_keys`, SSH host keys, or passwords.

## Validate before import

```bash
skm config validate trust-config.skm
```

Validation checks the complete file before any local metadata is changed. It
rejects malformed records, duplicate names or fingerprints, duplicate policy
rules, policy references to missing or retired identities, and policy machine
aliases that are not present in the current node's `skm host list`.

That last check is deliberate: a full policy import is only safe when the target
SKM node understands the same machine aliases.

## Import

```bash
skm config import trust-config.skm
```

Import replaces the local identity registry and policy only after full
validation. Existing files are backed up with `pre-import` timestamps and the
replacement files are written with mode `0600`.

Import does not change SSH authorization. A restored policy may therefore reveal
`MISSING` or `EXCESS` drift on the next check, but it never grants or revokes a
key by itself.

## Synchronize identities to another SKM node

For nodes that should share the same canonical fingerprint registry, plan first:

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

Remote sync uses the normal SKM config location on the target:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/ssh-key-manager
```

or a remotely defined `SKM_CONFIG_DIR` when that variable is available to the
non-interactive SSH session.

## JSON output

Trust checks can now produce compact machine-readable JSON while preserving their
normal exit status.

```bash
skm policy check --json
skm audit --json
```

Example success:

```json
{"command":"policy-check","version":"1.5.0","ok":true,"exit_code":0,"issue_count":0,"issues":[],"findings":[]}
```

Example drift:

```json
{"command":"policy-check","version":"1.5.0","ok":false,"exit_code":1,"issue_count":2,"issues":["MISSING phone -> server-b","EXCESS phone -> server-a"],"findings":[{"code":"POLICY_MISSING","severity":"warning","message":"MISSING phone -> server-b"},{"code":"POLICY_EXCESS","severity":"warning","message":"EXCESS phone -> server-a"}]}
```

The legacy `issues` strings remain for compatibility, while `findings` adds
stable machine-readable codes such as `POLICY_MISSING` and `POLICY_EXCESS`.
These commands are suitable for cron, systemd timers, CI jobs, monitoring hooks,
or other automation without parsing human terminal output.

## Recommended authoritative-node workflow

A small homelab can keep one SKM node authoritative for desired-state policy
while still sharing the identity registry to another management node:

```bash
# authoritative node
skm config export "$HOME/skm-trust-backup.skm"
skm sync identities "Mac Mini"
skm policy check --json
skm audit --json
```

The secondary node gets canonical identity names and statuses, but keeps its own
host aliases and does not acquire a second independently drifting policy copy.
