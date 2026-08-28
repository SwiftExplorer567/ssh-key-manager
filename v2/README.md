# SSH Key Manager V2 beta

V2 is a side-by-side Go rewrite of SKM. Production `skm` v1 remains untouched; beta binaries install as `skm2` / `skm-v2-beta`.

V2 is a local-first SSH access-control plane for small fleets. It never centralizes private keys and delegates SSH transport to the system OpenSSH client.

## Product model

V2 separates concepts that v1 intentionally compressed:

- **Subject** — human/device/service identity.
- **Credential** — one public-key fingerprint owned by a Subject. Rotating a key no longer changes identity.
- **Node** — stable machine identity.
- **Principal** — SSH account on a Node.
- **Route** — a connection path. The schema represents direct, Tailscale, SSH-config and ProxyJump routes; beta.1 remote mutation currently supports direct routes only.
- **Policy** — desired Subject-to-Principal authorization with `observe`, `additive` or `authoritative` mode.
- **Observed grant** — authorization actually present in `authorized_keys`.
- **Control-plane credential** — the separate restricted V2 controller key used only to reach the daemonless bridge. It is not treated as a user/application grant in inspect output.

## beta.1 scope

Implemented and testable now:

- schema-v2 local state with stable, namespace-separated IDs and atomic `0600` writes;
- deterministic v1 metadata migration of machines, identities, desired policy and SKM-pinned host keys without remote mutation;
- Subject → Credential and Node → Principal → Route representation;
- `observe`, `additive` and `authoritative` planning;
- unobserved Principals never produce planned changes;
- external/unmanaged credentials are preserved even in authoritative mode;
- plan snapshots carry both fleet revision and observed remote revision;
- dedicated V2 controller key (`~/.ssh/id_ed25519_skm2` by default);
- pinned-host, `IdentitiesOnly=yes`, fail-closed OpenSSH transport;
- restricted daemonless bridge enrollment using a forced command — no listener and no generic shell access for the V2 management key;
- live `inspect → plan → apply` through the restricted bridge;
- stale-plan and stale-remote-revision rejection;
- revision-guarded rollback;
- reversible restricted-key unenrollment through the bootstrap SSH credential;
- managed-key ownership stored in a separate `0600` bridge sidecar rather than inferred from user-controlled key comments;
- bridge lock, symlink refusal, backup, second revision check and atomic replacement;
- local operation history for apply/rollback;
- full-state backup excluding private keys;
- JSON-native CLI output;
- real OpenSSH CI covering arbitrary-shell refusal and the complete enroll/inspect/plan/apply/stale-reject/rollback/unenroll lifecycle.

Still intentionally incomplete in beta.1:

- direct routes are the only controller transport currently wired; Tailscale-route selection, SSH-config and ProxyJump are modelled but not yet executed by the controller;
- V2 host-trust discovery/rotation commands are not yet exposed (migrated V1 pins are preserved and enforced);
- Subject/Node groups and credential rotation/retirement workflows are not yet exposed in the CLI;
- multi-node resume/automatic rollback orchestration is not yet implemented;
- interactive TUI, package-manager installation and final update UX are not yet complete.

## Local build

```bash
go test ./...
go vet ./...
go build -o ./bin/skm2 ./cmd/skm2
```

## V1 migration

Preview first:

```bash
./bin/skm2 migrate v1 ~/.config/ssh-key-manager
```

Save only after reviewing:

```bash
./bin/skm2 migrate v1 ~/.config/ssh-key-manager --save
./bin/skm2 status
```

A saved migration creates V2 metadata only. It does **not** edit local or remote `authorized_keys`.

Repeated migration is deterministic for the same V1 metadata. Saving over an existing V2 workspace is refused unless `--force` is explicitly supplied.

## Restricted enrollment

Remote mutation is never enabled merely by migrating metadata. A target must already have pinned host trust and must be explicitly enrolled:

```bash
./bin/skm2 node enroll "Mac Mini" --yes
./bin/skm2 node bridge-version "Mac Mini"
./bin/skm2 node inspect "Mac Mini"
```

By default enrollment uses the existing v1 SKM key (`~/.ssh/id_ed25519_skm`) as the bootstrap credential and creates a separate V2 controller key at `~/.ssh/id_ed25519_skm2`. Both paths can be overridden with `SKM2_BOOTSTRAP_KEY` / `SKM2_MANAGED_KEY` or the enrollment CLI option.

The V2 controller key is written to the target as a restricted forced-command authorization. Possession of that key must not provide a generic SSH shell. `node inspect` presents this fingerprint separately as a control-plane credential instead of mixing it into application/user grants.

### Side-by-side V1 coexistence

While a target is enrolled in V2 beta, a v1 audit run from a v1 controller can report the separate `skm2-controller` fingerprint as an **unknown authorized fingerprint**. That warning is expected: v1 has no concept of a V2 control-plane credential and V2 intentionally does not weaken v1 auditing by trusting comments or key options as an ignore signal.

This warning does not mean the V2 key has unrestricted access; enrollment installs it with OpenSSH `restrict` plus a forced bridge command. `skm policy check` can still remain clean because the V2 control-plane key is not a v1 desired application grant. After `node unenroll`, the V2 authorization is removed and v1 audit should return to its pre-enrollment state.

Remove the V2 restricted authorization again with the bootstrap credential:

```bash
./bin/skm2 node unenroll "Mac Mini" --yes
```

## Policy, live plan and apply

A new Subject can be given a public credential and desired access:

```bash
./bin/skm2 subject add smoke-test service
./bin/skm2 credential import smoke-test ~/.ssh/smoke-test.pub
./bin/skm2 policy grant smoke-test "Mac Mini"
./bin/skm2 policy mode "Mac Mini" authoritative
```

Create a live plan from the enrolled target:

```bash
./bin/skm2 plan --node "Mac Mini" --out /tmp/skm2-plan.json
cat /tmp/skm2-plan.json
```

Mutation requires an explicit confirmation flag and rechecks both fleet and remote revisions:

```bash
./bin/skm2 apply /tmp/skm2-plan.json --yes
```

Reusing that old plan after remote state changes is refused. A successful apply returns the new remote revision, which can be used for an explicit rollback:

```bash
./bin/skm2 node rollback "Mac Mini" --expected NEW_REVISION --yes
```

Trailing `authorized_keys` comments are never trusted as ownership metadata. Only fingerprints recorded by the restricted bridge in its protected managed-state sidecar are eligible for V2-managed revocation.
