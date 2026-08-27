# Migrating to 1.2

SKM 1.2 is backward compatible with the existing host inventory and managed-key workflow. The new identity registry starts empty and does not change `authorized_keys` by itself.

After upgrading:

```bash
skm identity list
skm key list
```

Register fingerprints you have independently verified:

```bash
skm identity add workstation SHA256:... device
skm identity add server-a SHA256:... server
skm identity add deploy-prod SHA256:... service
```

Then review observed access and run the read-only audit:

```bash
skm access matrix
skm audit
```

Do not revoke an unknown or retired key until you have verified what owns it and confirmed replacement access where required.
