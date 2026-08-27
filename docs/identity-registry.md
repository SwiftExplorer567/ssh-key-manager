# Identity registry and trust audit

SSH Key Manager 1.2 adds a local identity layer on top of OpenSSH fingerprints.
The fingerprint is the identity anchor; the comment embedded in a public key is
only untrusted display metadata.

## Registry

Registry data lives in:

```text
~/.config/ssh-key-manager/identities.conf
```

The file is local metadata with mode `0600`. It contains no private keys and is
never intended to be committed to the SKM repository.

Each record stores:

```text
NAME|SHA256:FINGERPRINT|TYPE|STATUS
```

Supported types are `device`, `server`, `service`, and `other`. Supported
statuses are `active` and `retired`.

Use the CLI instead of editing the file directly:

```bash
skm identity add laptop SHA256:... device
skm identity add build-runner SHA256:... service
skm identity list
skm identity show laptop
skm identity rename laptop workstation
skm identity retire build-runner
skm identity activate build-runner
```

Names and fingerprints must be unique. Renaming an identity does not change the
fingerprint mapping.

## Identity-aware key display

`skm key list` and key-selection menus prefer the canonical registry name when a
fingerprint is known. If a key is not registered, SKM falls back to its public
key comment after removing terminal control characters.

This matters because SSH public-key comments are arbitrary input. A comment may
be stale, misleading, or contain escape/control characters. SKM never treats a
comment as proof of identity.

## Observed access matrix

```bash
skm access matrix
```

The matrix answers one narrow question: is each registered fingerprint present
in the `authorized_keys` file of each reachable saved machine?

- `yes` — fingerprint is present.
- `no` — fingerprint is not present.
- `?` — the machine could not be inspected with current key-based access.

The matrix reports observed state. It is not yet a desired-state policy engine;
a `yes` entry does not by itself mean that access is intended.

## Trust audit

```bash
skm audit
```

When a registry exists, the audit reports:

- authorized fingerprints that are not registered;
- retired identities that are still authorized;
- duplicate authorized fingerprints;
- terminal control characters in public-key comments;
- duplicate local public identities across `.pub` files;
- local `.pub` paths that are symbolic links;
- broad `Host *` SSH config blocks that set `IdentityFile`;
- saved machines whose `authorized_keys` could not be inspected.

If the registry is empty, unknown-key checks are skipped so existing SKM users
can upgrade without immediately treating every current key as an incident.

The audit is read-only. It does not revoke keys or rewrite SSH configuration.
A non-zero exit status means at least one trust or hygiene issue was found.

## Recommended workflow

1. Run `skm key list` and identify fingerprints you recognize.
2. Register known devices, servers, and service identities.
3. Run `skm access matrix` to review observed authorization.
4. Run `skm audit` and investigate unknown or retired identities.
5. Revoke or clean up keys explicitly only after verifying replacement access.

Private keys remain on the machine that owns them throughout this workflow.
