# core — migrations

Placeholder. Versioned migration steps for the core module live here as
`NNN-description.sh`, executed in order by `upgrade/upgrade.sh` when moving
between tagged releases. Each step must be idempotent and must not assume the
stack is running (the upgrade runs them between `down` and `up`).

Covers: Postgres schema (Drizzle migrations run inside sentinel-api on boot),
Authentik config exports, Wazuh manager config, indexer ISM policy changes.
