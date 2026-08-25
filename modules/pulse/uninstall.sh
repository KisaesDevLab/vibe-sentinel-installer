#!/usr/bin/env bash
# modules/pulse/uninstall.sh — removes Uptime Kuma and, after the top-level
# uninstall.sh has offered a data export, its SQLite volume.
#
# The Kuma DB holds the uptime history that backs the monitoring-gap minutes in
# the Monthly Monitoring Report (REQ-011 evidence), so the volume is only
# dropped when REMOVE_VOLUMES=1 is set explicitly after the export prompt.
set -euo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"

docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf uptime-kuma || true

if [ "$REMOVE_VOLUMES" = "1" ]; then
  docker volume rm -f vibe-sentinel_uptime-kuma-data 2>/dev/null || true
fi
echo "pulse module removed (volumes removed: $REMOVE_VOLUMES)."
echo "Availability monitoring is now unmanaged: SENT-U-* alerts stop, and the Monthly Monitoring Report loses its monitoring-gap evidence (REQ-011)."
