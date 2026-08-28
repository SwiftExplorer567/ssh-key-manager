# SSH Key Manager V2 beta

V2 is a side-by-side Go rewrite of SKM. Production `skm` v1 remains untouched; beta binaries install as `skm2` / `skm-v2-beta`.

## Product model

V2 separates concepts that v1 intentionally compressed:

- **Subject** — human/device/service identity.
- **Credential** — one public-key fingerprint owned by a subject. Rotation no longer changes identity.
- **Node** — stable machine identity.
- **Principal** — SSH account on a node.
- **Route** — direct, Tailscale, SSH-config or ProxyJump connection path.
- **Policy** — desired subject-to-principal authorization with observe/additive/authoritative modes.
- **Observed grant** — what is actually present in `authorized_keys`.

The controller remains local-first and never stores private keys.

## beta.1 scope

Implemented and testable now:

- schema-v2 local state with stable IDs and atomic 0600 writes;
- v1 metadata migration (`servers.conf`, `identities.conf`, `policy.conf`) without remote mutation;
- Subject → Credential and Node → Principal → Route representation;
- observe/additive/authoritative planning;
- unmanaged credentials are preserved even in authoritative mode;
- plan snapshots carry fleet + remote revisions;
- restricted daemonless bridge script with inspect/apply/rollback, symlink refusal, lock, backup and stale-revision rejection;
- full-state backup excluding private keys;
- JSON-native CLI output.

Remote `apply`, route probing, host pin enrollment and interactive TUI are being built on top of this beta core; beta.1 intentionally refuses to offer a generic remote mutation path before restricted enrollment is in place.

## local build

```bash
go test ./...
go vet ./...
go build -o ./bin/skm2 ./cmd/skm2
```

## v1 migration preview

```bash
./bin/skm2 migrate v1 ~/.config/ssh-key-manager
```

Save only after reviewing:

```bash
./bin/skm2 migrate v1 ~/.config/ssh-key-manager --save
./bin/skm2 status
```

This migration changes V2 metadata only. It does not edit any local or remote `authorized_keys` file.
