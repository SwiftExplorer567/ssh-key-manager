# Desired-state SSH policy

SSH Key Manager 1.3 adds an optional desired-state layer on top of the v1.2
identity registry and observed access matrix.

The v1.2 commands answer **what is authorized now?**. The v1.3 policy commands
also answer **what should be authorized?** and report drift between those two
states.

## Storage model

Desired-state policy is local metadata stored in:

```text
~/.config/ssh-key-manager/policy.conf
```

The file is created with mode `0600`. Each rule stores:

```text
SHA256:FINGERPRINT|MACHINE_NAME
```

The fingerprint, not the identity name, anchors the rule. Renaming an identity
therefore does not invalidate its policy expectations.

Machine names refer to the names in `skm host list`. Policy files are local to
the SKM installation; machine names do not need to be identical on different
management machines.

## Closed-world semantics

An empty policy preserves the v1.2 observed-only behavior. `skm audit` does not
flag registered active identities as excess when no policy rules exist.

Once at least one policy rule is configured, the policy becomes closed-world
for registered **active** identities:

- a rule exists and the fingerprint is authorized: `OK`;
- a rule exists but the fingerprint is absent: `MISSING`;
- no rule exists but the fingerprint is authorized: `EXCESS`;
- no rule exists and the fingerprint is absent: `-`;
- the machine could not be inspected: `?`.

Unknown authorized fingerprints and retired authorized identities continue to
be handled by the v1.2 trust audit independently of desired-state drift.

## Commands

Create expectations without changing SSH authorization:

```bash
skm policy expect workstation server-a
skm policy expect phone server-a
skm policy expect workstation server-b
```

Review the rules:

```bash
skm policy list
```

Compare policy with observed authorization:

```bash
skm policy matrix
```

Example output:

```text
IDENTITY                 TYPE      STATUS    server-a       server-b
workstation              device    active    OK             MISSING
phone                    device    active    EXCESS         -
```

Use a CI- or script-friendly drift check:

```bash
skm policy check
```

The command exits non-zero if it finds `MISSING`, `EXCESS`, a stale rule for an
unknown machine/fingerprint, a retired identity still referenced by policy, or
an unreachable machine that prevents a complete check.

Remove an expectation:

```bash
skm policy remove workstation server-b
```

Removing a policy rule **does not revoke the SSH key**. It only changes desired
state. Use the existing `skm access revoke` workflow for an intentional access
change after reviewing replacement access and impact.

## Audit integration

When policy is configured, `skm audit` includes desired-state findings together
with the v1.2 trust and hygiene checks. Typical findings are:

```text
warn  server-a: EXCESS identity 'phone' is authorized but not expected.
warn  server-b: MISSING expected identity 'workstation'.
```

The audit remains read-only. SKM 1.3 does not automatically add or revoke keys.
This separation is deliberate: policy describes intent; access commands perform
changes explicitly.

## Recommended workflow

1. Register identities with `skm identity add`.
2. Confirm the observed baseline with `skm access matrix` and `skm audit`.
3. Add each intended identity-to-machine pair with `skm policy expect`.
4. Review `skm policy matrix` until all intended cells are `OK` or `-`.
5. Run `skm policy check` or `skm audit` periodically to detect drift.
6. Investigate `MISSING` and `EXCESS` before changing authorization.
