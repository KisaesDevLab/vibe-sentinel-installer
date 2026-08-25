#!/usr/bin/env bash
# modules/core/uninstall.sh — stops and removes core services and (after the
# top-level uninstall.sh has offered a data export) their volumes.
set -euo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"

svcs="sentinel-backup cloudflared sentinel-web sentinel-worker sentinel-api \
      wazuh-dashboard wazuh-manager wazuh-indexer ntfy sentinel-certs \
      authentik-worker authentik-server sentinel-redis sentinel-db"
# shellcheck disable=SC2086
docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf $svcs || true

if [ "$REMOVE_VOLUMES" = "1" ]; then
  for v in pg-data redis-data authentik-media wazuh-manager-config \
           wazuh-manager-data wazuh-indexer-data ntfy-data; do
    docker volume rm -f "vibe-sentinel_${v}" 2>/dev/null || true
  done
fi
echo "core module removed (volumes removed: $REMOVE_VOLUMES)"
