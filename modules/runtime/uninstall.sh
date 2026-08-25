#!/usr/bin/env bash
# modules/runtime/uninstall.sh
set -euo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"
docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf falco falcosidekick || true
echo "runtime module removed. NOTE: disabling runtime detection weakens REQ-010 coverage; record the decision in the change log."
