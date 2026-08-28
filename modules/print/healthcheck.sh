#!/usr/bin/env bash
# modules/print/healthcheck.sh — Vibe Print probe.
#
# Rewritten 2026-08-28 alongside the retarget onto
# ghcr.io/kisaesdevlab/vibe-printer. The previous version probed three services
# and three published ports that the real image does not have, and asserted a
# CONTENT_INSPECTION env var it does not read — so it would have failed against
# a perfectly healthy gateway.
#
# What is still worth asserting, and why:
#   1. The container is up and /readyz is green. /readyz answers 200 only when
#      the SQLite handle AND the delivery worker are both live; a gateway whose
#      worker has died still serves the admin UI while quietly printing nothing.
#   2. The listener is on the mesh interface ONLY. A 0.0.0.0 binding would put
#      an endpoint whose sole credential is one shared secret on every
#      interface the host has, which is exactly what the print isolation model
#      exists to prevent.
#   3. Payloads are discarded after printing.
#   4. The printer network policy has been applied (SENT-PR-002).
set -uo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"

ok=0

cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q vibe-printer 2>/dev/null | head -n1)"
if [ -z "$cid" ]; then
  echo "FAIL vibe-printer: not running"
  exit 1
fi
state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
case "$state" in
  running/healthy|running/none) echo "OK   vibe-printer ($state)" ;;
  *) echo "FAIL vibe-printer ($state)"; ok=1 ;;
esac

mesh_ip="$(grep -m1 '^MESH_BIND_IP=' "$ENVF" 2>/dev/null | cut -d= -f2)"
mesh_ip="${mesh_ip:-127.0.0.1}"

# The single published listener must be mesh-bound.
bindings="$(docker compose -f "$COMPOSE" --env-file "$ENVF" port vibe-printer 8080 2>/dev/null)"
if [ -z "$bindings" ]; then
  echo "FAIL the gateway has no published binding"
  ok=1
elif printf '%s' "$bindings" | grep -q '^0\.0\.0\.0:'; then
  echo "FAIL the gateway is bound to 0.0.0.0 - it must bind $mesh_ip only (§2.2 print isolation)"
  ok=1
else
  echo "OK   gateway bound to ${bindings%%$'\n'*}"
fi

# Readiness, not merely liveness: 503 here means the delivery worker is down
# and jobs are accumulating with nothing to send them.
if curl -fsS -o /dev/null --max-time 5 "http://$mesh_ip:8632/readyz"; then
  echo "OK   /readyz green on $mesh_ip:8632 (database + delivery worker)"
else
  echo "FAIL /readyz not green on $mesh_ip:8632 - the gateway is not accepting work"
  ok=1
fi

# Decision 24 (no content inspection) is now a property of the architecture
# rather than a switch: the gateway is HANDED a payload by a caller and renders
# it, so there is no print stream to intercept. What is still worth checking is
# that payloads are not retained after printing, which is the setting that
# decides whether client document content sits in the job table.
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null \
   | grep -qi '^VIBE_PRINT_STORE_PAYLOADS=false'; then
  echo "OK   payloads discarded after printing; only a content hash is kept"
else
  echo "FAIL VIBE_PRINT_STORE_PAYLOADS is not false - rendered client documents are being retained in the job store"
  ok=1
fi

# Host firewall isolation, if printer-network-policy.sh has been applied.
if [ -f "$SENTINEL_ETC/modules/print/.printer-policy-applied" ]; then
  echo "OK   printer network policy applied ($(cat "$SENTINEL_ETC/modules/print/.printer-policy-applied"))"
else
  echo "WARN printer network policy not applied — run modules/print/printer-network-policy.sh so only this host reaches printer ports (SENT-PR-002)"
fi

# Features the compliance scorecard must not claim until they ship upstream.
echo "WARN held release (Decision 26) and the scanner inbox (SENT-PR-009) are not implemented upstream - do not record them as active controls"

exit "$ok"
