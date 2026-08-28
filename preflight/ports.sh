#!/usr/bin/env bash
# preflight/ports.sh — §2.6 host port map conflict check, including against
# other Vibe appliances sharing the host.
#
# THE PORT MAP IS NOT IN THIS FILE ANY MORE. It is read from each selected
# module's manifest.json (`hostPorts`), which is the same file the appliance's
# console reads. The hand-maintained copy that used to live here had already
# drifted from reality in both directions: it was missing 443 (Vaultwarden) and
# 3001 (Uptime Kuma) entirely, and it still listed 631 and 9100 for a print
# module that no longer publishes them. Neither gap was visible from this file.
#
# Two further defects fixed 2026-08-28:
#
#   1. 443 was never checked, so the one guaranteed collision on a host shared
#      with the Vibe Appliance — its Caddy on 0.0.0.0:443 against Vaultwarden's
#      <mesh-ip>:443 in mesh_only mode — was walked straight past.
#   2. `grep docker-proxy` treated EVERY docker-published port on the host as
#      "ours on a re-run". docker-proxy is the process behind every container
#      publish from any project, so the one conflict class this check exists to
#      find was precisely the one it ignored. Ownership now comes from asking
#      Docker which compose project publishes the port.
# shellcheck shell=bash

# Ports published by containers in OUR compose project. Anything listening on a
# port that is not in this set belongs to somebody else, including another Vibe
# appliance's container — which is exactly what needs catching.
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
        m = json.load(open(os.path.join(d, f), encoding='utf-8'))
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
  # shellcheck source=../lib/manifests.sh
  [ -n "${MANIFESTS_ROOT:-}" ] || . "$INSTALLER_ROOT/lib/manifests.sh"

  local -a checks=()
  local port proto bind req label line

  # Every non-optional host port the selected modules declare. `optional` marks
  # a publish that only happens behind a per-module opt-in (NetBird's relay is
  # the only one today), so it is checked below rather than here — a firm
  # without the relay must not be told 3478 is in use by something else.
  while read -r port proto bind req label; do
    [ -n "$port" ] || continue
    [ "$req" = "optional" ] && continue
    checks+=("$port/$proto $label ($bind)")
  done <<EOF
$(manifest_host_ports ${SELECTED_MODULES:-core})
EOF

  # The relay is the ONE possible inbound port on the whole appliance and stays
  # off until a failed NAT test plus QI consent. Its manifest entry is marked
  # optional; this is the opt-in that turns it on.
  if [ "$(config_get '.modules.mesh.relay_enabled' 'false')" = "true" ]; then
    checks+=("3478/udp NetBird relay (opt-in)")
  fi

  if [ ${#checks[@]} -eq 0 ]; then
    pf_fail "No host ports resolved from the selected modules ($SELECTED_MODULES). Every module ships a manifest.json declaring what it publishes; a missing or unreadable one means this check verified nothing. Look for modules/<id>/manifest.json."
    return 1
  fi

  local ours
  ours="$(_sentinel_published_ports)"

  local entry conflict=0 listeners proc owner
  for entry in "${checks[@]}"; do
    port="${entry%%/*}"
    proto="$(printf '%s' "$entry" | cut -d/ -f2 | cut -d' ' -f1)"
    label="${entry#* }"
    if [ "$proto" = "udp" ]; then
      listeners="$(ss -lnup "sport = :$port" 2>/dev/null | tail -n +2)"
    else
      listeners="$(ss -lntp "sport = :$port" 2>/dev/null | tail -n +2)"
    fi
    [ -n "$listeners" ] || continue

    # Already ours, from a previous run of this installer.
    if printf '%s\n' "$ours" | grep -qx "$port"; then
      continue
    fi

    proc="$(printf '%s' "$listeners" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2)"
    if owner="$(_appliance_port_owner "$port")"; then
      pf_fail "Port $port/$proto ($label) is already published by $owner. Both cannot bind it. Either move Sentinel to its own host, or - for 443 specifically - run Vaultwarden in tunnel mode instead of mesh_only so it does not need the mesh listener. Sentinel's port map is declared in modules/<id>/manifest.json."
    else
      pf_fail "Port $port/$proto ($label) is already in use by '${proc:-unknown process}'. If another appliance or service owns it, move that service or run Sentinel on a dedicated host. Sentinel's port map is declared in modules/<id>/manifest.json."
    fi
    conflict=1
  done

  if [ "$conflict" -eq 0 ]; then
    pf_pass "No conflicts on the Sentinel host port map (${#checks[@]} ports for: $SELECTED_MODULES)."
    return 0
  fi
  return 1
}
