#!/usr/bin/env bash
# preflight/ports.sh — §2.6 host port map conflict check, including against
# other Vibe appliances sharing the host. Sentinel binds:
#   1514/tcp, 1515/tcp   Wazuh agent enrollment/events (mesh interface)
#   55000/tcp            Wazuh API (loopback)
#   9200/tcp             OpenSearch (loopback)
#   443/tcp              Vaultwarden (mesh interface, mesh_only mode)    [keys]
#   3001/tcp             Uptime Kuma (mesh interface)                   [pulse]
#   8632/tcp             Vibe Print gateway + admin UI (mesh interface) [print]
#   8085/tcp             ntfy (mesh interface)
#   8080/tcp             CrowdSec LAPI (loopback)                        [edge]
#   9392/tcp             Greenbone dashboard (loopback)                  [scan]
#   3478/udp             NetBird relay — ONLY if the opt-in relay is enabled
#
# TWO DEFECTS FIXED 2026-08-28, both of which made this check quieter than it
# looked:
#
#   1. 443 was never checked. Vaultwarden binds ${MESH_BIND_IP}:443 in
#      mesh_only mode and the Vibe Appliance's Caddy binds 0.0.0.0:443 — a
#      guaranteed collision on a shared host that this file walked straight
#      past. 3001 (Uptime Kuma) was missing for the same reason.
#   2. `grep docker-proxy` treated EVERY docker-published port on the host as
#      "ours on a re-run". docker-proxy is the process behind every container
#      publish from any project, so the one conflict class this check exists to
#      find — another Vibe appliance already owning the port — was precisely
#      the one it ignored. Ownership is now decided by asking Docker which
#      compose project publishes the port, not by the process name.
#
# The print module's entry shrank from 631/9100/8632/445/21/2525/30000-30009 to
# a single port when it was retargeted onto the image the Vibe-Printer repo
# actually publishes: that gateway dials OUT to printers and listens only on
# its own API port. See modules/print/compose.yml.
# shellcheck shell=bash

# Ports published by containers in OUR compose project. Anything listening on a
# port that is not in this set is somebody else's, including another Vibe
# appliance's container — which is exactly what we need to catch.
_sentinel_published_ports() {
  docker ps --filter 'label=com.docker.compose.project=vibe-sentinel' \
            --format '{{.Ports}}' 2>/dev/null \
    | tr ',' '\n' \
    | sed -n 's/.*:\([0-9]\+\)->.*/\1/p' \
    | sort -u
}

# Name the other appliance when it is the thing in the way, so the operator is
# told WHO owns the port rather than being handed a pid. The appliance's fixed
# publishes are not in any manifest (its Caddy and emergency proxy are core
# services, not apps), so they are listed here; manifest-declared hostPorts are
# read too, for units that grow one later.
_appliance_port_owner() { # port
  local port="$1"
  local dir="${VIBE_APPLIANCE_DIR:-/opt/vibe/appliance}"
  [ -d "$dir" ] || return 1
  case "$port" in
    80|443) printf 'the Vibe Appliance (Caddy, which fronts every Vibe app)'; return 0 ;;
    517[1-9]|518[0-9]|519[0-9])
      printf 'the Vibe Appliance (emergency access proxy, ports 5171-5198)'; return 0 ;;
  esac
  local hit
  hit="$(python3 - "$dir/console/manifests" "$port" <<'PYEOF' 2>/dev/null || true
import json, os, sys
d, port = sys.argv[1], int(sys.argv[2])
try:
    names = sorted(os.listdir(d))
except OSError:
    sys.exit(0)
for f in names:
    if not f.endswith('.json') or f.startswith('_'):
        continue
    try:
        m = json.load(open(os.path.join(d, f)))
    except Exception:
        continue
    for p in (m.get('hostPorts') or []):
        lo = p.get('port')
        hi = p.get('portEnd', lo)
        if lo is not None and lo <= port <= hi:
            print("the Vibe Appliance's %s (%s)" % (m.get('slug', f), p.get('label', '')))
            sys.exit(0)
PYEOF
)"
  [ -n "$hit" ] || return 1
  printf '%s' "$hit"
}

preflight_ports() {
  local -a checks=()
  checks+=("1514/tcp Wazuh agent events")
  checks+=("1515/tcp Wazuh agent enrollment")
  checks+=("55000/tcp Wazuh API (loopback)")
  checks+=("9200/tcp OpenSearch (loopback)")
  checks+=("8085/tcp ntfy")
  if module_selected edge;  then checks+=("8080/tcp CrowdSec LAPI (loopback)"); fi
  if module_selected print; then checks+=("8632/tcp Vibe Print gateway"); fi
  if module_selected pulse; then checks+=("3001/tcp Uptime Kuma"); fi
  if module_selected scan;  then checks+=("9392/tcp Greenbone dashboard (loopback)"); fi
  # Vaultwarden's mesh listener is the published endpoint in mesh_only mode and
  # a mesh fallback in tunnel mode, so it binds either way.
  if module_selected keys;  then checks+=("443/tcp Vaultwarden (mesh)"); fi
  if [ "$(config_get '.modules.mesh.relay_enabled' 'false')" = "true" ]; then
    checks+=("3478/udp NetBird relay")
  fi

  local ours
  ours="$(_sentinel_published_ports)"

  local entry port proto label conflict=0 listeners
  for entry in "${checks[@]}"; do
    port="${entry%%/*}"
    proto="$(printf '%s' "$entry" | cut -d/ -f2 | cut -d' ' -f1)"
    label="${entry#*/tcp }"; label="${label#*/udp }"
    if [ "$proto" = "udp" ]; then
      listeners="$(ss -lnup "sport = :$port" 2>/dev/null | tail -n +2)"
    else
      listeners="$(ss -lntp "sport = :$port" 2>/dev/null | tail -n +2)"
    fi
    [ -n "$listeners" ] || continue

    # Ours already, from a previous run of this installer.
    if printf '%s\n' "$ours" | grep -qx "$port"; then
      continue
    fi

    local proc owner
    proc="$(printf '%s' "$listeners" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2)"
    if owner="$(_appliance_port_owner "$port")"; then
      pf_fail "Port $port/$proto ($label) is already published by $owner. Both cannot bind it. Either move Sentinel to its own host, or - for 443 specifically - run Vaultwarden in tunnel mode instead of mesh_only so it does not need the mesh listener. Sentinel's port map is fixed (plan §2.6)."
    else
      pf_fail "Port $port/$proto ($label) is already in use by '${proc:-unknown process}'. If another appliance or service owns it, move that service or run Sentinel on a dedicated host. Sentinel's port map is fixed (plan §2.6)."
    fi
    conflict=1
  done

  if [ "$conflict" -eq 0 ]; then
    pf_pass "No conflicts on the Sentinel host port map for selected modules."
    return 0
  fi
  return 1
}
