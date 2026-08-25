#!/usr/bin/env bash
# modules/scan/uninstall.sh — removes Greenbone and, after the top-level
# uninstall.sh has offered a data export, its volumes.
#
# Scan results already imported into `vulnerability_scan` / `vulnerability`
# live in the Sentinel database and are NOT touched here; what goes away is
# Greenbone's own store and the several GB of feed data.
set -euo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"

svcs="gsa gvmd ospd-openvas gb-mqtt gb-redis gb-pg"
# shellcheck disable=SC2086
docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf $svcs || true

if [ "$REMOVE_VOLUMES" = "1" ]; then
  for v in gb-pg-data gb-gvmd-data gb-scap-data gb-cert-data gb-vt-data \
           gb-notus-data gb-psql-socket gb-gvmd-socket gb-ospd-socket gb-redis-socket; do
    docker volume rm -f "vibe-sentinel_${v}" 2>/dev/null || true
  done
fi
echo "scan module removed (volumes removed: $REMOVE_VOLUMES)."
echo "Network-facing vulnerability scanning stops. Wazuh's vulnerability detector still covers installed packages on every agent,"
echo "but printers, network gear, and any agentless host are no longer scanned — note that in the risk assessment (REQ-012)."
