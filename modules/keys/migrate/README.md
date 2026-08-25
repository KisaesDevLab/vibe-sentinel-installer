# keys — migrations

Versioned migration steps for the Vaultwarden module live here as
`NNN-description.sh`, executed in order by `upgrade/upgrade.sh` when moving
between tagged releases. Each step must be idempotent and must not assume the
stack is running (the upgrade runs them between `down` and `up`).

**Vaultwarden upgrades are harness-gated.** `upgrade/upgrade.sh` refuses to move
Vaultwarden unless `versions/manifest.json` marks `harness_passed: true` for the
target version: Vaultwarden performs schema migrations on first boot with no
supported downgrade, so an unverified jump is a one-way door for the firm's
password vault.

Covers:

- The `vaultwarden` database on the shared Sentinel Postgres instance
  (Decision 19) — Vaultwarden runs its own Diesel migrations on boot; steps
  here only handle anything Sentinel adds alongside it.
- `/data` contents that must survive: `attachments/`, `sends/`, `icon_cache/`,
  and above all **`rsa_key*`** — losing the RSA keypair invalidates every
  client's stored auth state. §2.4 backs these up on every run.
- Org policy re-application after an upgrade that resets or adds policy fields
  (require 2FA, master password min 14 + complexity, single org, disable
  personal ownership, disable Send, reset-password auto-enroll, QI emergency
  access). Sentinel verifies each policy via the API after applying it.
- `ORG_EVENTS_ENABLED` / `EVENTS_DAYS_RETAIN` continuity so the SENT-K-* rules
  and the REQ-028 adoption report do not lose their event source.

## Pre-upgrade checklist for this module

1. A Vault (or built-in restic) snapshot tagged `vaultwarden` exists and is
   less than 24h old — DB, attachments, and `rsa_key*`.
2. No maintenance window is open: `keys/healthcheck.sh` must report
   `/admin disabled at rest`.
3. The restore test for this module has passed within the current quarter,
   including a real login check (§2.4).
