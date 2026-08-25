#!/usr/bin/env bash
# modules/keys/uninstall.sh — removes Vaultwarden and, once the top-level
# uninstall.sh has offered a data export, its volume.
#
# A firm that loses its password vault has lost access to everything (§2.4),
# so this refuses to drop the volume unless REMOVE_VOLUMES=1 is set explicitly
# by the top-level uninstall after the export prompt.
set -euo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"

docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf vaultwarden || true

# Tunnel-mode Cloudflare artifacts created by tunnel-mode-setup.sh.
if [ -f "$SENTINEL_ETC/secrets/cf_api_token" ]; then
  TOKEN="$(cat "$SENTINEL_ETC/secrets/cf_api_token")"
  DOMAIN="$(jq -r '.firm.domain // empty' "$SENTINEL_ETC/config.json" 2>/dev/null || true)"
  if [ -n "${DOMAIN:-}" ]; then
    ZONE_ID="$(curl -sS -H "Authorization: Bearer $TOKEN" \
      "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')"
    if [ -n "$ZONE_ID" ]; then
      # Rate-limit rules live in the http_ratelimit ruleset entrypoint; drop the
      # two rules this module added by description.
      RS_ID="$(curl -sS -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets?phase=http_ratelimit" \
        | jq -r '.result[]? | select(.phase=="http_ratelimit") | .id' | head -n1)"
      if [ -n "${RS_ID:-}" ]; then
        KEEP="$(curl -sS -H "Authorization: Bearer $TOKEN" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RS_ID" \
          | jq '[.result.rules[]? | select((.description // "") | startswith("vibe-sentinel: vaultwarden") | not)]')"
        curl -sS -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          --data "$(jq -n --argjson r "$KEEP" '{rules:$r}')" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/rulesets/$RS_ID" >/dev/null || true
      fi
    fi
  fi
fi

if [ "$REMOVE_VOLUMES" = "1" ]; then
  docker volume rm -f vibe-sentinel_vaultwarden-data 2>/dev/null || true
  rm -rf "${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}/keys"
fi
echo "keys module removed (volumes removed: $REMOVE_VOLUMES)."
echo "Security Six #3 (password manager) now needs a recorded compensating control (e.g. 1Password Business)."
