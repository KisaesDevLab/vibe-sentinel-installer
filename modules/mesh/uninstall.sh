#!/usr/bin/env bash
# modules/mesh/uninstall.sh
set -euo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"
docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf netbird-management netbird-signal netbird-dashboard netbird-relay || true
if [ "$REMOVE_VOLUMES" = "1" ]; then
  docker volume rm -f vibe-sentinel_netbird-mgmt-data vibe-sentinel_netbird-signal-data 2>/dev/null || true
fi
echo "mesh module removed. Security Six #6 (VPN/private network) now needs a recorded compensating control (e.g. Tailscale)."
