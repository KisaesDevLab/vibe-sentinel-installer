#!/usr/bin/env bash
# preflight/sysctl.sh — vm.max_map_count >= 262144 (the Wazuh indexer /
# OpenSearch will not start otherwise). Sets it persistently via
# /etc/sysctl.d/99-sentinel.conf (plan §2.6).
# shellcheck shell=bash

preflight_sysctl() {
  local want=262144 cur
  cur="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if [ "$cur" -ge "$want" ]; then
    pf_pass "vm.max_map_count=$cur (>= $want) — OpenSearch can start."
    return 0
  fi

  log "vm.max_map_count=$cur is below $want — setting it persistently."
  printf '# Vibe Sentinel: OpenSearch (Wazuh indexer) requirement\nvm.max_map_count = %s\n' "$want" \
    >/etc/sysctl.d/99-sentinel.conf
  if sysctl -w vm.max_map_count="$want" >/dev/null && sysctl --system >/dev/null 2>&1; then
    pf_pass "vm.max_map_count raised to $want and persisted in /etc/sysctl.d/99-sentinel.conf."
    return 0
  fi
  pf_fail "Could not set vm.max_map_count to $want. The Wazuh event indexer (OpenSearch) will not start below that value. Set it manually: echo 'vm.max_map_count = 262144' > /etc/sysctl.d/99-sentinel.conf && sysctl --system"
  return 1
}
