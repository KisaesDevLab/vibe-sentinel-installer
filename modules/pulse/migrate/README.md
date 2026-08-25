# pulse — migrations

Versioned migration steps for the Uptime Kuma module live here as
`NNN-description.sh`, executed in order by `upgrade/upgrade.sh` when moving
between tagged releases. Each step must be idempotent and must not assume the
stack is running (the upgrade runs them between `down` and `up`).

**Uptime Kuma upgrades are harness-gated — this is the strictest gate in the
appliance.** The socket.io API Kuma exposes is *unversioned* and has changed
between releases within the v2 line. The Sentinel worker's monitor adapter is
written against exactly one verified build (Phase 0 note (c)), so
`upgrade/upgrade.sh` refuses to move this image unless
`versions/manifest.json` marks `harness_passed: true` for the target version.
A silent adapter break does not look like an outage — monitors simply stop
being created and updated, and nobody notices until an incident.

Covers:

- The SQLite database in the `uptime-kuma-data` volume (Kuma runs its own
  Knex migrations on boot; steps here handle anything Sentinel adds).
- Re-assertion of the `auto-managed` tag semantics after an upgrade that
  changes tag or monitor payload shapes. Hand-made monitors must survive
  untouched.
- Maintenance-window sync with the Sentinel maintenance window, so planned
  downtime keeps not being an incident across the upgrade.
- Status-page templates (internal and the optional client-facing page) and the
  Access bypass on the status path only.

## Pre-upgrade checklist for this module

1. `versions/manifest.json` → `images["uptime-kuma"].harness_passed == true`
   for the target tag, set by a real adapter run against that build.
2. A Vault (or built-in restic) snapshot tagged `uptime-kuma` exists.
3. Export the monitor list before the upgrade so a diff can prove nothing was
   dropped: the adapter's `monitors:export` command writes JSON to the
   evidence store.
