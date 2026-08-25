#!/usr/bin/env bash
# modules/mesh/healthcheck.sh
set -uo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"
ok=0
for svc in netbird-management netbird-signal netbird-dashboard; do
  cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q "$svc" 2>/dev/null | head -n1)"
  if [ -z "$cid" ] || [ "$(docker inspect -f '{{.State.Status}}' "$cid")" != "running" ]; then
    echo "FAIL $svc"; ok=1
  else
    echo "OK   $svc"
  fi
done
# Relay only if enabled
if jq -e '.modules.mesh.relay_enabled == true' /etc/vibe-sentinel/config.json >/dev/null 2>&1; then
  docker ps --format '{{.Names}}' | grep -q netbird-relay \
    && echo "OK   netbird-relay (opt-in enabled)" \
    || { echo "FAIL netbird-relay (enabled but not running)"; ok=1; }
fi
exit "$ok"
