#!/usr/bin/env bash
# modules/runtime/healthcheck.sh
set -uo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"
ok=0
for svc in falco falcosidekick; do
  cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q "$svc" 2>/dev/null | head -n1)"
  if [ -z "$cid" ] || [ "$(docker inspect -f '{{.State.Status}}' "$cid")" != "running" ]; then
    echo "FAIL $svc"; ok=1
  else
    echo "OK   $svc"
  fi
done
exit "$ok"
