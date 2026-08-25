# scan — migrations

Versioned migration steps for the Greenbone module live here as
`NNN-description.sh`, executed in order by `upgrade/upgrade.sh` when moving
between tagged releases. Each step must be idempotent and must not assume the
stack is running (the upgrade runs them between `down` and `up`).

Covers:

- The `gvmd` database in Greenbone's own Postgres (`gb-pg`). gvmd runs a
  schema migration on start (`gvmd --migrate`) and the container will refuse
  to serve until it completes — a step here must wait for it rather than time
  out the health gate.
- Feed data: VT, SCAP, CERT, and Notus. A major-version jump can invalidate
  the on-disk feed format; the step must trigger a resync and the operator must
  expect hours, not minutes, before the first post-upgrade scan is meaningful.
- Scan configs, targets, schedules, and credentials for authenticated scans.
  Targets are firm subnets reached over the mesh, so a mesh addressing change
  invalidates them.
- The loopback binding. Every upgrade must leave `gsa` published on
  `127.0.0.1:9392` and nowhere else (§2.6) — `healthcheck.sh` asserts this.

## Pre-upgrade checklist for this module

1. No scan is running. Interrupting a scan mid-flight leaves partial results
   that import as a false all-clear.
2. Results since the last import have been pulled into `vulnerability_scan` /
   `vulnerability` — the Sentinel database is the record of truth, and the
   Greenbone store is disposable by design.
3. Enough free disk for a full feed resync alongside the existing feed.
