#!/bin/sh
# Minimal built-in restic backup job (§2.4, profile "no-vault").
# For firms WITHOUT Vibe Vault, so Sentinel is never unbacked. Backs up, with
# a per-dataset restic tag: all Postgres databases (sentinel, authentik,
# vaultwarden, vibe_print) via pg_dump, plus the Sentinel data dir (certs,
# module state). Runs once daily inside the firm's backup window.
# Vibe Vault, when present, replaces this job entirely (install.sh detects it).
set -eu

REPO="${RESTIC_REPOSITORY:?}"
WINDOW="${BACKUP_WINDOW:-01:00-03:00}"

in_window() {
  now=$(date +%H%M)
  start=$(echo "$WINDOW" | cut -d- -f1 | tr -d ':')
  end=$(echo "$WINDOW" | cut -d- -f2 | tr -d ':')
  if [ "$start" -le "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -le "$end" ]
  else
    [ "$now" -ge "$start" ] || [ "$now" -le "$end" ]
  fi
}

restic snapshots >/dev/null 2>&1 || restic init

LAST_RUN_DAY=""
while true; do
  today=$(date +%Y-%m-%d)
  if [ "$today" != "$LAST_RUN_DAY" ] && in_window; then
    echo "[backup] starting daily restic run ($today, window $WINDOW)"
    workdir=$(mktemp -d)
    for db in sentinel authentik vaultwarden vibe_print; do
      echo "[backup] pg_dump $db"
      pg_dump -Fc -d "$db" -f "$workdir/$db.dump" || echo "[backup] WARN: pg_dump $db failed" >&2
    done
    restic backup --tag sentinel-postgres "$workdir" && rm -rf "$workdir"
    restic backup --tag sentinel-data /data/sentinel
    restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
    restic check --read-data-subset=5% || echo "[backup] WARN: restic check failed (SENT-B-003)" >&2
    LAST_RUN_DAY="$today"
    echo "[backup] daily run complete"
  fi
  sleep 300
done
