# RFC-003 — Restricted SSH bridge

Recommended V2 enrollment installs a tiny daemonless bridge and authorizes the controller key with an OpenSSH forced command plus restrictive key options. The bridge uses stdin/stdout, opens no listening port and never offers an interactive shell.

Protocol v1 exposes `version`, `inspect`, revision-guarded `apply`, and revision-guarded `rollback`. Mutations reject symlinked `authorized_keys`, acquire an exclusive lock, create a backup, write a 0600 temporary file and atomically rename it. An expected revision mismatch aborts before mutation.
