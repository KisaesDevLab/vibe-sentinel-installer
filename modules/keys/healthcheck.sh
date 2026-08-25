#!/usr/bin/env bash
# modules/keys/healthcheck.sh — Vaultwarden probe. Beyond "is it running", this
# asserts the two posture facts Phase 7K cares about: the /admin panel is OFF
# at rest (ADMIN_TOKEN unset), and no stale maintenance window is open.
set -uo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
MARKER="${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}/keys/maintenance-mode.json"

ok=0
cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q vaultwarden 2>/dev/null | head -n1)"
if [ -z "$cid" ]; then
  echo "FAIL vaultwarden: not running"
  exit 1
fi
state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
case "$state" in
  running/healthy|running/none) echo "OK   vaultwarden ($state)" ;;
  *) echo "FAIL vaultwarden ($state)"; ok=1 ;;
esac

# ADMIN_TOKEN must be absent at rest — the /admin panel is disabled in
# production and only maintenance-mode.sh may turn it on (Decision: 30-minute
# auto-reverting maintenance mode with a change record).
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null | grep -q '^ADMIN_TOKEN='; then
  echo "FAIL vaultwarden /admin is ENABLED (ADMIN_TOKEN is set on the container)"
  echo "     If this is not an approved maintenance window, revert now:"
  echo "     bash $SENTINEL_ETC/modules/keys/maintenance-mode.sh --off"
  ok=1
else
  echo "OK   /admin disabled at rest (ADMIN_TOKEN unset)"
fi

# A marker left behind past its expiry means the auto-revert did not fire.
if [ -s "$MARKER" ]; then
  expires="$(jq -r '.expires_at // empty' "$MARKER" 2>/dev/null)"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$expires" ] && [ "$expires" \< "$now" ]; then
    echo "FAIL maintenance-mode marker expired at $expires but was never reverted"
    echo "     Run: bash $SENTINEL_ETC/modules/keys/maintenance-mode.sh --off"
    ok=1
  else
    echo "OK   maintenance window open until $expires (change record pending pickup)"
  fi
fi

# Published-mode sanity: in tunnel mode the origin must be plain HTTP because
# cloudflared is configured with service http://vaultwarden:80.
mode="$(jq -r '.modules.keys.vaultwarden_mode // "tunnel"' "$SENTINEL_ETC/config.json" 2>/dev/null)"
if [ "$mode" = "mesh_only" ]; then
  [ -s "${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}/certs/live/wildcard.crt" ] \
    && echo "OK   mesh_only mode: wildcard certificate present for TLS termination" \
    || { echo "FAIL mesh_only mode but no wildcard certificate (sentinel-certs)"; ok=1; }
fi
exit "$ok"
