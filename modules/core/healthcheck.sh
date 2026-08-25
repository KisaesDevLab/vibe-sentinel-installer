#!/usr/bin/env bash
# modules/core/healthcheck.sh — module-level health probe used by install.sh
# re-runs, upgrade.sh, and operators. Exit 0 = healthy.
set -uo pipefail
COMPOSE="${SENTINEL_COMPOSE:-/etc/vibe-sentinel/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-/etc/vibe-sentinel/.env}"

ok=0
for svc in sentinel-db sentinel-redis authentik-server sentinel-api sentinel-web \
           sentinel-certs cloudflared ntfy wazuh-indexer wazuh-manager wazuh-dashboard; do
  cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q "$svc" 2>/dev/null | head -n1)"
  if [ -z "$cid" ]; then echo "FAIL $svc: not running"; ok=1; continue; fi
  state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
  case "$state" in
    running/healthy|running/none) echo "OK   $svc ($state)" ;;
    *) echo "FAIL $svc ($state)"; ok=1 ;;
  esac
done
[ -s /var/lib/vibe-sentinel/certs/live/wildcard.crt ] \
  && echo "OK   wildcard certificate present" \
  || { echo "FAIL wildcard certificate missing (sentinel-certs)"; ok=1; }
exit "$ok"
