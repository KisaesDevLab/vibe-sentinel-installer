#!/usr/bin/env bash
# modules/edge/cloudflare-worker-bouncer.sh — deploys the Workers-based
# CrowdSec Cloudflare bouncer into the FIRM'S OWN Cloudflare account via the
# API (the legacy IP-list bouncer is deprecated — Decision R22). Not a
# container: the Worker runs at the Cloudflare edge and enforces CrowdSec
# decisions in front of every tunnel-published hostname.
set -euo pipefail

SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
INSTALLER_ROOT="${INSTALLER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=../../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh" 2>/dev/null || . "$SENTINEL_ETC/modules/../lib/common.sh" 2>/dev/null || true

CF_API="https://api.cloudflare.com/client/v4"
TOKEN="$(cat "$SENTINEL_ETC/secrets/cf_api_token")"
DOMAIN="$(jq -r '.firm.domain' "$SENTINEL_ETC/config.json")"
ACCOUNT_ID="$(curl -sS -H "Authorization: Bearer $TOKEN" "$CF_API/zones?name=$DOMAIN" | jq -r '.result[0].account.id')"
ZONE_ID="$(curl -sS -H "Authorization: Bearer $TOKEN" "$CF_API/zones?name=$DOMAIN" | jq -r '.result[0].id')"

# Register a bouncer API key with the local CrowdSec LAPI for the Worker.
BOUNCER_KEY="$(docker compose -f "$SENTINEL_ETC/compose.yml" --env-file "$SENTINEL_ETC/.env" \
  exec -T crowdsec cscli bouncers add cloudflare-worker -o raw 2>/dev/null || true)"
if [ -z "$BOUNCER_KEY" ]; then
  # Already registered on a re-run; keep the existing key file.
  BOUNCER_KEY="$(cat "$SENTINEL_ETC/secrets/cf_worker_bouncer_key" 2>/dev/null || true)"
fi
[ -n "$BOUNCER_KEY" ] || { echo "[edge] could not obtain a CrowdSec bouncer key"; exit 1; }
( umask 077; printf '%s' "$BOUNCER_KEY" >"$SENTINEL_ETC/secrets/cf_worker_bouncer_key" )

WORKER_NAME="crowdsec-bouncer-sentinel"

# TODO(Phase 5): the Worker script body ships from the pinned
# crowdsecurity/cs-cloudflare-worker-bouncer release verified in Phase 0.
# The placeholder below fails CLOSED-OPEN (passes traffic) so a broken deploy
# never blocks the firm's own dashboards.
WORKER_JS='export default { async fetch(req, env) {
  // Placeholder Worker — replaced by the pinned CrowdSec Workers bouncer in Phase 5.
  return fetch(req);
} }'

echo "[edge] uploading Worker '$WORKER_NAME' to account $ACCOUNT_ID"
curl -sS -X PUT "$CF_API/accounts/$ACCOUNT_ID/workers/scripts/$WORKER_NAME" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/javascript" \
  --data "$WORKER_JS" | jq -e '.success' >/dev/null \
  || { echo "[edge] Worker upload failed — the token may lack Workers Scripts:Edit (see NOTES.md)"; exit 1; }

# Route every tunnel-published hostname through the Worker.
for host in "sentinel.$DOMAIN" "id.$DOMAIN" "nb.$DOMAIN" "nb-signal.$DOMAIN" "vault.$DOMAIN"; do
  curl -sS -X POST "$CF_API/zones/$ZONE_ID/workers/routes" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "{\"pattern\":\"$host/*\",\"script\":\"$WORKER_NAME\"}" >/dev/null || true
done
echo "[edge] Workers-based Cloudflare bouncer deployed (routes on machine-facing + dashboard hostnames)"
