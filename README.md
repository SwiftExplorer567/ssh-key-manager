# SSH Key Manager v1

SSH access management for humans. SKM makes the direction of every access grant
explicit and never transfers a private key.

## The mental model

An SSH connection always has a direction:

```text
this machine  ── public key ──>  server authorized_keys
this machine  ── signs in ────>  server
```

| What you want | Command | What changes |
|---|---|---|
| Connect from here to `storage` | `skm access grant storage` | This machine's public key is allowed on `storage` |
| Let `storage` connect back here | `skm access receive storage` | `storage`'s public key is allowed on this machine |
| Connect both ways | `skm access link storage` | The two public keys are allowed in opposite directions |
| Open an SSH session | `skm connect storage` | No access files change |

Each machine owns a dedicated `~/.ssh/id_ed25519_skm` keypair. The private half
stays on that machine. Two-way access means two separate private keys and two
public access grants—not a copied private key.

## Install

Linux and macOS with Bash 3.2+ and OpenSSH are supported.

```bash
curl -fsSL https://raw.githubusercontent.com/SwiftExplorer567/ssh-key-manager/main/install.sh | bash
```

The installer uses `/usr/local/bin` when it is writable, otherwise
`~/.local/bin`. Remote installs download the versioned release asset and its
SHA-256 file, verify the checksum, and validate the script with `bash -n` before
installation. To explicitly request a system install:

```bash
curl -fsSL https://raw.githubusercontent.com/SwiftExplorer567/ssh-key-manager/main/install.sh | bash -s -- --system
```

## Two-server quick start

On server A:

```bash
skm host add server-b admin 192.168.1.20 22
skm access link server-b
```

The first step of `link` can ask for server B's SSH password once. SKM then:

1. creates a dedicated ED25519 key on A if needed;
2. adds A's public key to B;
3. creates a separate dedicated ED25519 key on B if needed;
4. adds B's public key to A;
5. leaves both private keys on their original machines.

Afterward:

```bash
skm connect server-b
skm access status server-b
```

If password login is disabled and there is no existing SSH path, use an offline
public-key exchange:

```bash
# On server A
skm key public

# On server B: paste the line printed by A
skm access allow -
```

Repeat in the other direction if you need two-way access.

## Interactive use

Run `skm` with no arguments to open the full-screen dashboard. Use arrow keys or
`j`/`k` to move, Enter to select, number shortcuts for direct selection, and
`q` to go back. The dashboard uses user goals, not SSH file jargon:

1. Quick connect
2. Set up passwordless access
3. See access directions
4. Machines
5. Keys & security
6. Updates

Saved machines show `ready`, `unavailable`, or `this machine` status badges.
Quick Connect and Access Setup list only remote machines, preventing accidental
self-selection. The confirmation screen always displays an explicit direction
such as `THIS MACHINE → storage` before changing access.

## Updates

SKM checks the latest GitHub release tag at most once every 24 hours and shows a
dashboard badge when an update exists. Checks can be disabled from the Updates
screen or with `AUTO_UPDATE_CHECK="false"` in the config file. Updates are never
installed silently.

```bash
skm update check
skm update install
```

Installation downloads the versioned release executable and checksum over
HTTPS, verifies SHA-256, confirms the embedded version and shebang, runs
`bash -n`, preserves the current binary as `.previous`, and then replaces it
atomically. System installs request `sudo` only after explicit update
confirmation.

## Commands

```text
skm host list
skm host add NAME USER HOST [PORT]
skm host remove NAME
skm host test NAME

skm access grant NAME [KEY.pub]
skm access receive NAME
skm access link NAME [KEY.pub]
skm access status [NAME]
skm access revoke NAME
skm access allow [KEY.pub|-]

skm connect NAME [SSH_ARGS...]
skm quick NAME [SSH_ARGS...]

skm key list
skm key generate [PATH] [COMMENT]
skm key public [KEY.pub]
skm doctor
skm update check
skm update install
```

The old `give-access` and `get-access` language is intentionally rejected with a
directional replacement message.

## Configuration and compatibility

Legacy host records remain compatible:

```text
name|user|host|port
```

Files:

- `~/.config/ssh-key-manager/servers.conf` — saved machines
- `~/.config/ssh-key-manager/config` — optional `BRAND`,
  `STRICT_HOST_KEY_CHECKING`, and `AUTO_UPDATE_CHECK` settings
- `~/.config/ssh-key-manager/update.state` — cached release check, refreshed at
  most once every 24 hours
- `~/.ssh/id_ed25519_skm` — local SKM private key (mode `0600`)
- `~/.ssh/id_ed25519_skm.pub` — its public half
- `~/.ssh/authorized_keys.skm.bak` — most recent pre-change backup

Existing v2 host configuration is read without executing it. Settings are
allow-listed; the config file is never sourced as shell code.

## Security properties

- private keys are never read for transfer and never leave their owner;
- only validated public key lines are accepted;
- host, user, port, and machine names are validated before SSH use;
- `authorized_keys` updates are locked, atomic, permissioned, and backed up;
- symlinked `authorized_keys` files are rejected;
- remote commands are fixed scripts and public keys travel over standard input,
  not through shell interpolation;
- there is no telemetry or silent update installation; the optional startup
  request only checks the latest versioned GitHub release tag;
- `skm doctor` checks permissions, symlinks, and legacy RSA/DSA grants.

New hosts default to `StrictHostKeyChecking=accept-new`, which prevents changed
host keys but trusts a first-seen key. For pre-provisioned `known_hosts`, set:

```text
STRICT_HOST_KEY_CHECKING="yes"
```

## Architecture and development

Development sources are separated by responsibility:

- `src/runtime.sh` — environment, configuration, output, and validation;
- `src/hosts.sh` — host persistence and host operations;
- `src/ssh_transport.sh` — SSH invocation and remote transport;
- `src/access.sh` — keys, grants, revocation, and security checks;
- `src/updates.sh` — release discovery, checksum validation, and updates;
- `src/ui.sh` — terminal UI and interactive flows;
- `src/cli.sh` — help, command dispatch, and application entry point;
- `remote/` — remote `authorized_keys` programs embedded at build time.

`build/bundle.sh` combines these sources into the single distributable
`ssh-key-manager` executable and its `ssh-key-manager.sha256` checksum. Both
generated files are committed so direct install URLs remain available; CI
rejects stale generated output.

```bash
make build
make check-generated
make test
make lint
make ci
```

Tests are split by runtime/hosts, access, updates/install, UI/CLI, and
uninstall/release behavior. They run with isolated temporary HOME/config/SSH
directories and never touch the developer's real SSH files. CI runs generated
artifact checks, the functional suite, syntax validation, and ShellCheck on
Linux and macOS.

## Uninstall

The default uninstaller preserves both SSH keys and saved host configuration:

```bash
curl -fsSL https://raw.githubusercontent.com/SwiftExplorer567/ssh-key-manager/main/uninstall.sh | bash -s -- --yes
```

Add `--purge` to remove SKM's host configuration. `~/.ssh` is never removed.
For an installation made with `install.sh --prefix DIR`, pass the same location
to the uninstaller:

```bash
./uninstall.sh --yes --prefix DIR
```

## License

MIT — see [LICENSE](LICENSE).
