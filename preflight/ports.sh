#!/usr/bin/env bash
# preflight/ports.sh — §2.6 host port map conflict check, including against
# other Vibe appliances sharing the host. Sentinel binds:
#   1514/tcp, 1515/tcp   Wazuh agent enrollment/events (mesh interface)
#   55000/tcp            Wazuh API (loopback)
#   9200/tcp             OpenSearch (loopback)
#   631/tcp, 9100/tcp    Vibe Print IPP + legacy raw (mesh interface)   [print]
#   8085/tcp             ntfy (mesh interface)
#   8080/tcp             CrowdSec LAPI (loopback)                        [edge]
#   9392/tcp             Greenbone dashboard (loopback)                  [scan]
#   3478/udp             NetBird relay — ONLY if the opt-in relay is enabled
# shellcheck shell=bash

preflight_ports() {
  local -a checks=()
  checks+=("1514/tcp Wazuh agent events")
  checks+=("1515/tcp Wazuh agent enrollment")
  checks+=("55000/tcp Wazuh API (loopback)")
  checks+=("9200/tcp OpenSearch (loopback)")
  checks+=("8085/tcp ntfy")
  if module_selected edge;  then checks+=("8080/tcp CrowdSec LAPI (loopback)"); fi
  if module_selected print; then checks+=("631/tcp Vibe Print IPP" "9100/tcp Vibe Print legacy raw"); fi
  if module_selected scan;  then checks+=("9392/tcp Greenbone dashboard (loopback)"); fi
  if [ "$(config_get '.modules.mesh.relay_enabled' 'false')" = "true" ]; then
    checks+=("3478/udp NetBird relay")
  fi

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
    # Ignore our own containers on a re-run.
    if [ -n "$listeners" ] && ! printf '%s' "$listeners" | grep -q 'docker-proxy\|vibe-sentinel'; then
      local proc
      proc="$(printf '%s' "$listeners" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2)"
      pf_fail "Port $port/$proto ($label) is already in use by '${proc:-unknown process}'. If another Vibe appliance or service owns it, move that service or run Sentinel on a dedicated host. Sentinel's port map is fixed (plan §2.6)."
      conflict=1
    fi
  done

  if [ "$conflict" -eq 0 ]; then
    pf_pass "No conflicts on the Sentinel host port map for selected modules."
    return 0
  fi
  return 1
}
