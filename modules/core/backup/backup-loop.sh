#!/bin/sh
# Minimal built-in restic backup job (§2.4, profile "no-vault").
# For firms WITHOUT Vibe Vault, so Sentinel is never unbacked. Backs up, with
# a per-dataset restic tag: all Postgres databases (sentinel, authentik,
# vaultwarden) via pg_dump, plus the Sentinel data dir (certs, module state)
# and the print gateway's SQLite. Runs once daily inside the firm's backup
# window.
#
# The print gateway keeps ALL of its state - jobs, printers, templates, and the
# tamper-evident audit chain - in SQLite inside the print-data volume, so it is
# backed up as a directory rather than a pg_dump. It was a Postgres database
# until the module was retargeted onto the real product on 2026-08-28; without
# the mount below it would have become the one dataset nothing covered.
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
    for db in sentinel authentik vaultwarden; do
      echo "[backup] pg_dump $db"
      pg_dump -Fc -d "$db" -f "$workdir/$db.dump" || echo "[backup] WARN: pg_dump $db failed" >&2
    done
    restic backup --tag sentinel-postgres "$workdir" && rm -rf "$workdir"
    restic backup --tag sentinel-data /data/sentinel
    # Present only when the print module is enabled; skip quietly otherwise.
    # An `if` rather than `test && cmd`: under `set -e` a trailing test that
    # evaluates false aborts the loop, which would have killed the forget,
    # prune and check steps below on every install without the print module.
    if [ -d /data/print ]; then
      restic backup --tag sentinel-print /data/print
    fi
    restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
    restic check --read-data-subset=5% || echo "[backup] WARN: restic check failed (SENT-B-003)" >&2
    LAST_RUN_DAY="$today"
    echo "[backup] daily run complete"
  fi
  sleep 300
done
