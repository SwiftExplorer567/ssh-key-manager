# RFC-005 — Install, update and migration

V2 beta installs side-by-side as `skm2`; it does not overwrite production v1. The preferred future channels are Homebrew plus signed/attested release binaries for Linux and macOS. A package-managed install must not self-overwrite; standalone builds may use an explicit verified updater.

V1 migration is metadata-only and previews before saving. Hosts become Nodes + Principals + Routes, identity fingerprints become Credentials owned by Subjects, and desired policy is translated to stable ID references. Remote SSH authorization is never changed as part of migration.
