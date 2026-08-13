# SSH Key Manager v1

Public key management for humans. SKM keeps a clear inventory across your
machines and lets you grant or revoke access without ever moving a private key.
It deliberately does not open interactive SSH sessions.

## The mental model

An SSH connection always has a direction:

```text
this machine  ── public key ──>  server authorized_keys
this machine  ── signs in ────>  server
```

| What you want | Where to do it | What changes |
|---|---|---|
| Let this device access `rpi5` | Dashboard → Give Access → This device | This device's public key is allowed on `rpi5` |
| Let a new client access one server | Dashboard → Give Access → Another device | The pasted client public key is added to one destination |
| Let a new client access every managed server | Dashboard → Give Access → Another device → All | The same client public key is added to each destination |
| Review keys across the fleet | Keys & Security → Key inventory | Nothing; only public metadata is read |

Each machine owns a dedicated `~/.ssh/id_ed25519_skm` keypair. The private half
stays on that machine. Access is always granted by copying only a public key to
a destination's `authorized_keys` file.

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

## Mac mini + Raspberry Pi quick start

Install SKM on the Mac mini, open `skm`, then choose **Machines → Add a
machine**. Enter a friendly name such as `rpi5`, its SSH user, IP address, and
port. When asked, let SKM give the Mac mini access to the Pi. The Pi's login
password may be requested once so its `authorized_keys` can be updated.

The equivalent CLI commands are:

```bash
skm host add rpi5 homelab 192.168.1.20 22
skm access grant rpi5
```

SKM creates a dedicated ED25519 key on the Mac mini if needed and adds only its
public half to the Pi. The private half stays on the Mac mini.

## Give a new client access

On the client device, run:

```bash
skm key public
```

If the client has no SKM key, this creates one on that client and prints only
the safe-to-share public line. On the Mac mini, choose **Give Access → Another
device**, paste that line, and choose one destination or all saved machines.
SKM does not copy or escrow the client's private key.

If password login is disabled and the manager cannot yet reach a server, install
the public key through the server's console or provisioning system first.

## Interactive use

Run `skm` with no arguments to open the full-screen dashboard. Use arrow keys or
`j`/`k` to move, Enter to select, number shortcuts for direct selection, and
`q` to go back. The dashboard uses user goals, not SSH file jargon:

1. Give Access
2. Machines
3. Keys & Security
4. Access Overview
5. Updates

Saved machines show `ready`, `unavailable`, or `this machine` status badges.
The Key Inventory shows public identities and authorized public keys for the
local device and every reachable saved machine. Unreachable machines are marked
without blocking the rest of the inventory. The confirmation screen always
displays the exact source and destination before changing access.

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
- inventory reads only `*.pub` and `authorized_keys` public data;
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
