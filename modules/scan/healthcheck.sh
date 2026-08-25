#!/usr/bin/env bash
# modules/scan/healthcheck.sh — Greenbone probe.
#
# First boot syncs the VT, SCAP, CERT, and Notus feeds and can take hours; a
# gvmd that is up but has no feed is not a working scanner, so this reports
# feed state rather than pretending everything is fine.
set -uo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"

ok=0
for svc in gb-pg gb-redis gb-mqtt gvmd ospd-openvas gsa; do
  cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q "$svc" 2>/dev/null | head -n1)"
  if [ -z "$cid" ]; then echo "FAIL $svc: not running"; ok=1; continue; fi
  state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
  case "$state" in
    running/healthy|running/none) echo "OK   $svc ($state)" ;;
    *) echo "FAIL $svc ($state)"; ok=1 ;;
  esac
done

# The web UI must answer on LOOPBACK and must NOT be reachable from anywhere
# else. A scanner exposed on the mesh or a LAN interface is a serious finding.
if curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:9392/; then
  echo "OK   Greenbone web UI on 127.0.0.1:9392"
else
  echo "FAIL Greenbone web UI not answering on 127.0.0.1:9392"
  ok=1
fi
binding="$(docker compose -f "$COMPOSE" --env-file "$ENVF" port gsa 80 2>/dev/null || true)"
case "$binding" in
  127.0.0.1:*) echo "OK   gsa published on loopback only ($binding)" ;;
  "") echo "FAIL gsa has no published port binding"; ok=1 ;;
  *) echo "FAIL gsa is published on '$binding' — §2.6 requires 127.0.0.1:9392 only"; ok=1 ;;
esac

# Feed status. Empty plugin/SCAP directories mean the first sync has not
# finished (or is failing), and any scan run now would report a false all-clear.
cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q ospd-openvas 2>/dev/null | head -n1)"
if [ -n "$cid" ]; then
  vts="$(docker exec "$cid" sh -c 'ls /var/lib/openvas/plugins 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  if [ "${vts:-0}" -gt 100 ]; then
    echo "OK   VT feed present ($vts plugin files)"
  else
    echo "WARN VT feed not synced yet ($vts files) — first boot can take several hours; scans run before the sync completes will under-report"
  fi
fi
exit "$ok"
