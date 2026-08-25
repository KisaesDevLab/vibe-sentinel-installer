#!/usr/bin/env bash
# modules/print/healthcheck.sh — Vibe Print probe.
#
# Beyond "are the three services up", this asserts the two posture facts Phase
# 8P depends on: the printer listeners are bound to the mesh interface ONLY
# (never 0.0.0.0), and content inspection is off (Decision 24).
set -uo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"

ok=0
for svc in vibe-print vibe-print-release vibe-print-scanner-inbox; do
  cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q "$svc" 2>/dev/null | head -n1)"
  if [ -z "$cid" ]; then echo "FAIL $svc: not running"; ok=1; continue; fi
  state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
  case "$state" in
    running/healthy|running/none) echo "OK   $svc ($state)" ;;
    *) echo "FAIL $svc ($state)"; ok=1 ;;
  esac
done

mesh_ip="$(grep -m1 '^MESH_BIND_IP=' "$ENVF" 2>/dev/null | cut -d= -f2)"
mesh_ip="${mesh_ip:-127.0.0.1}"

# Listeners must be on the mesh interface only. A 0.0.0.0 binding would put the
# raw-9100 listener on every interface the host has — exactly what the print
# isolation model exists to prevent.
for port in 631 9100 8632; do
  bindings="$(docker compose -f "$COMPOSE" --env-file "$ENVF" port vibe-print "$port" 2>/dev/null \
              || docker compose -f "$COMPOSE" --env-file "$ENVF" port vibe-print-release "$port" 2>/dev/null)"
  if [ -z "$bindings" ]; then
    echo "FAIL port $port has no published binding"
    ok=1
  elif printf '%s' "$bindings" | grep -q '^0\.0\.0\.0:'; then
    echo "FAIL port $port is bound to 0.0.0.0 — it must bind $mesh_ip only (§2.2 print isolation)"
    ok=1
  else
    echo "OK   port $port bound to ${bindings%%$'\n'*}"
  fi
done

# IPP endpoint answers.
if curl -fsSk -o /dev/null --max-time 5 "https://$mesh_ip:631/" \
   || curl -fsS -o /dev/null --max-time 5 "http://$mesh_ip:631/"; then
  echo "OK   IPP endpoint reachable on $mesh_ip:631"
else
  echo "FAIL IPP endpoint not reachable on $mesh_ip:631"
  ok=1
fi

# Decision 24: no content inspection, ever.
cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q vibe-print 2>/dev/null | head -n1)"
if [ -n "$cid" ]; then
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null \
     | grep -q '^CONTENT_INSPECTION=disabled'; then
    echo "OK   content inspection disabled (Decision 24)"
  else
    echo "FAIL CONTENT_INSPECTION is not 'disabled' on vibe-print — Vibe Print must never read job content"
    ok=1
  fi
fi

# Host firewall isolation, if printer-network-policy.sh has been applied.
if [ -f "$SENTINEL_ETC/modules/print/.printer-policy-applied" ]; then
  echo "OK   printer network policy applied ($(cat "$SENTINEL_ETC/modules/print/.printer-policy-applied"))"
else
  echo "WARN printer network policy not applied — run modules/print/printer-network-policy.sh so only this host reaches printer ports (SENT-PR-002)"
fi
exit "$ok"
