# Security Policy

SSH Key Manager works directly with SSH authorization state, so security reports
are treated as high priority.

## Supported versions

Security fixes are targeted at the latest published release. Older releases may
receive fixes only when a safe backport is practical.

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Older releases | Best effort |

Users should keep SKM current with:

```bash
skm update check
skm update install
```

## Reporting a vulnerability

Please **do not open a public GitHub issue for an undisclosed vulnerability**.

Use GitHub's private vulnerability reporting flow for this repository when it is
available. If private reporting is unavailable, contact the maintainer privately
through the GitHub account associated with this repository before publishing
technical details.

A useful report includes:

- affected SKM version;
- operating system and Bash/OpenSSH versions;
- the security boundary that can be crossed;
- minimal reproduction steps;
- whether exploitation requires local access, SSH access, or a malicious remote;
- expected versus observed behavior;
- a proposed fix or test case, if you have one.

Never include real private keys, authentication tokens, passwords, or unrelated
production secrets in a report.

## Security-sensitive areas

Changes in these areas deserve extra review:

- `authorized_keys` parsing or mutation;
- remote scripts in `remote/`;
- SSH argument construction and host validation;
- symlink and file-permission handling;
- public-key and fingerprint validation;
- trust config import/export;
- updater checksum/version verification;
- terminal rendering of attacker-controlled key comments;
- GitHub Actions release permissions and artifact publication.

## Security design principles

SKM is designed around several constraints:

- private keys stay on the machine that owns them;
- only public key material is copied to destinations;
- remote mutations use fixed application-owned programs;
- authorization/config replacement is validated, permissioned, and backed up;
- unsafe symlink targets are rejected;
- imported trust metadata is validated before mutation;
- updates are explicit and checksum verified;
- audit findings are read-only and never trigger automatic revocation.

These properties reduce risk, but SKM does not protect a host that is already
fully compromised and is not a replacement for normal SSH hardening, endpoint
security, backups, or least privilege.
