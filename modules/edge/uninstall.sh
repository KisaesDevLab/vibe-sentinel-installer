#!/usr/bin/env bash
# modules/edge/uninstall.sh — removes CrowdSec containers and the Cloudflare
# Worker routes deployed by cloudflare-worker-bouncer.sh.
set -euo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"

docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf crowdsec cs-firewall-bouncer || true

# Remove the Worker + routes if credentials are still present.
if [ -f "$SENTINEL_ETC/secrets/cf_api_token" ]; then
  TOKEN="$(cat "$SENTINEL_ETC/secrets/cf_api_token")"
  DOMAIN="$(jq -r '.firm.domain' "$SENTINEL_ETC/config.json" 2>/dev/null || true)"
  if [ -n "${DOMAIN:-}" ]; then
    ACCOUNT_ID="$(curl -sS -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].account.id // empty')"
    [ -n "$ACCOUNT_ID" ] && curl -sS -X DELETE \
      -H "Authorization: Bearer $TOKEN" \
      "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/workers/scripts/crowdsec-bouncer-sentinel" >/dev/null || true
  fi
fi
echo "edge module removed."
