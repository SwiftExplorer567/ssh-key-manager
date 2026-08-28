# RFC-001 — V2 product and threat model

SKM V2 is a local-first SSH access-control plane for small fleets. It manages identity metadata, host trust, desired authorization and public-key changes without escrow of private keys.

Security boundaries: controller state may contain public keys/fingerprints and topology but never private key material; host identity must be verified before privileged bootstrap; enrolled management credentials are restricted to the SKM bridge rather than arbitrary shells; external/manual authorization is preserved unless explicitly adopted; every mutation is revision guarded and auditable.

Non-goals: SSH terminal client, password vault, sudo/PAM manager, endpoint compromise detection, enterprise IAM, or a built-in SSH CA.
