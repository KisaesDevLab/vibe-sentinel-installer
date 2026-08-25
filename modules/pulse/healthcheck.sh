#!/usr/bin/env bash
# modules/pulse/healthcheck.sh — Uptime Kuma probe.
#
# Pulse is the thing that notices when the other safeguards stop; if pulse
# itself is down nobody is watching, so this also asserts that the pinned v2
# image is the one actually running (an unnoticed image drift breaks the
# socket.io adapter and silently stops monitor management).
set -uo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
MANIFEST="${MANIFEST_FILE:-/opt/vibe-sentinel-installer/versions/manifest.json}"

ok=0
cid="$(docker compose -f "$COMPOSE" --env-file "$ENVF" ps -q uptime-kuma 2>/dev/null | head -n1)"
if [ -z "$cid" ]; then
  echo "FAIL uptime-kuma: not running"
  exit 1
fi
state="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")"
case "$state" in
  running/healthy|running/none) echo "OK   uptime-kuma ($state)" ;;
  *) echo "FAIL uptime-kuma ($state)"; ok=1 ;;
esac

# Web UI answers on the mesh-bound port.
mesh_ip="$(grep -m1 '^MESH_BIND_IP=' "$ENVF" 2>/dev/null | cut -d= -f2)"
mesh_ip="${mesh_ip:-127.0.0.1}"
if curl -fsSk -o /dev/null --max-time 5 "https://$mesh_ip:3001/" \
   || curl -fsS -o /dev/null --max-time 5 "http://$mesh_ip:3001/"; then
  echo "OK   uptime-kuma UI reachable on $mesh_ip:3001"
else
  echo "FAIL uptime-kuma UI not reachable on $mesh_ip:3001"
  ok=1
fi

# Pinned-version assertion (Phase 0 note (c)): the socket.io API is unversioned.
if [ -s "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  want_tag="$(jq -r '.images["uptime-kuma"].tag // empty' "$MANIFEST")"
  running="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
  case "$running" in
    *"$want_tag"*|*@sha256:*) echo "OK   image matches the pinned v2 build ($running)" ;;
    *) echo "FAIL running image '$running' is not the pinned Uptime Kuma v2 build ('$want_tag')"
       echo "     The socket.io API is unversioned; the Sentinel monitor adapter is written against the pinned build."
       ok=1 ;;
  esac
fi
exit "$ok"
