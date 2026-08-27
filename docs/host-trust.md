# SSH host trust

SSH public-key authorization answers **who may enter a server**. SSH host-key
verification answers the opposite question: **which server did the client reach**.
Version 1.5 gives SSH Key Manager an explicit, local host-key trust store so a
management connection can enforce both sides of that relationship.

## Discover, verify, then pin

```bash
skm host fingerprint server-a
```

This uses `ssh-keyscan` against the saved host and port and displays SHA-256 host
key fingerprints. Discovery is not authentication: when host identity matters,
compare the fingerprint with a value obtained independently from the server, its
console, an administrator, or another trusted channel.

After verification, pin the exact fingerprint:

```bash
skm host trust server-a 'SHA256:...'
skm host verify server-a
```

Passing an expected fingerprint is non-interactive and fails if the server does
not currently present that key. Running `skm host trust server-a` without a
fingerprint displays the scan and asks for confirmation before storing it.

## What changes after pinning

SKM stores pins in:

```text
~/.config/ssh-key-manager/known_hosts
```

The file is local metadata with mode `0600`. For a pinned host, SKM forces:

```text
StrictHostKeyChecking=yes
UserKnownHostsFile=<SKM known_hosts>
GlobalKnownHostsFile=/dev/null
```

That means a global user/system known-host entry cannot silently override the
SKM pin for that management connection. If an SKM managed identity exists, the
same connection also uses `IdentitiesOnly=yes`.

## Verify or remove a pin

```bash
skm host verify server-a
skm host untrust server-a
```

`verify` rescans the saved endpoint and succeeds only if a pinned key is still
presented. `untrust` removes only the SKM pin; it does not edit system/global
`known_hosts` files or SSH authorization.

## Unpinned hosts

For backwards compatibility, unpinned hosts continue to use the configured
`STRICT_HOST_KEY_CHECKING` mode, which defaults to `accept-new`. That mode
rejects changed host keys but trusts a first-seen key. Explicit pinning is the
recommended mode for important servers.
