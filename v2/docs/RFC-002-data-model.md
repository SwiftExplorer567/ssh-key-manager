# RFC-002 — V2 state model

Stable security references use IDs, never display aliases. `Subject` owns one or more `Credential` objects. A `Node` owns `Principal` SSH accounts; each principal can have multiple prioritized `Route` objects. Policy references subject IDs and principal IDs, so key rotation and route/address changes do not rewrite intent.

Policy modes: `observe` never creates drift; `additive` reports missing desired grants while preserving extras; `authoritative` also plans revocation of extra **SKM-managed** grants. Unmanaged grants remain protected by default.
