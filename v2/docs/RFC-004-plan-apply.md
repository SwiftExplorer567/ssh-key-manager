# RFC-004 — Plan and apply

V2 separates observation from mutation. `plan` compares desired policy with observed grants and records both fleet revision and per-principal remote revisions. `apply` must re-check those revisions immediately before any remote write. A mismatch means the plan is stale and must be regenerated.

Multi-node operations are journaled by operation ID so partial failure can be resumed or rolled back. beta.1 lands the planner and bridge revision primitive first; controller-side remote apply follows only through the restricted bridge path.
