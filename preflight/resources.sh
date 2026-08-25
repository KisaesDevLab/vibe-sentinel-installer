#!/usr/bin/env bash
# preflight/resources.sh — Phase 18 resource preflight. Sentinel may share a
# host with other Vibe appliances or run dedicated; either way these minimums
# must be FREE, not merely installed.
#
#   core                4 cores / 8 GB   (includes Authentik)
#   +mesh               1 core  / 1 GB
#   +keys               0.5 c   / 512 MB
#   +pulse              0.5 c   / 512 MB
#   +print              0.5 c   / 512 MB
#   +scan               2 cores / 4 GB
#
# Disk is computed from agent count × retention with 30% headroom.
# shellcheck shell=bash

# Sizing constants — from the Phase 0 sizing table. PLACEHOLDER values until
# the Phase 0 dogfood baseline publishes measured numbers; marked so a later
# phase can grep for them.
EVENTS_PER_AGENT_PER_DAY=15000   # PLACEHOLDER — from Phase 0 sizing table
BYTES_PER_EVENT=900              # PLACEHOLDER — avg indexed event size, from Phase 0 sizing table
WARM_COMPRESSION_RATIO=20        # PLACEHOLDER — warm indices ~5% of hot size (ISM rollover), from Phase 0
BASE_DISK_GB=40                  # images + Postgres + module state, excludes event store

preflight_resources() {
  local agents retention_days
  agents="$(config_get '.firm.agent_count_estimate' "${AGENT_COUNT_ESTIMATE:-10}")"
  retention_days="$(config_get '.retention.warm_days' "${RETENTION_WARM_DAYS:-365}")"

  # --- CPU / RAM requirement from selected modules (tenths of a core, MB) ---
  local need_cpu10=40 need_mem=8192 m
  for m in ${SELECTED_MODULES:-core}; do
    case "$m" in
      mesh)  need_cpu10=$((need_cpu10 + 10)); need_mem=$((need_mem + 1024)) ;;
      keys)  need_cpu10=$((need_cpu10 + 5));  need_mem=$((need_mem + 512)) ;;
      pulse) need_cpu10=$((need_cpu10 + 5));  need_mem=$((need_mem + 512)) ;;
      print) need_cpu10=$((need_cpu10 + 5));  need_mem=$((need_mem + 512)) ;;
      scan)  need_cpu10=$((need_cpu10 + 20)); need_mem=$((need_mem + 4096)) ;;
    esac
  done

  local cores mem_avail_mb
  cores="$(nproc)"
  # MemAvailable reflects what is actually free for new workloads on a shared host.
  mem_avail_mb="$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)"

  local need_cores_disp="$((need_cpu10 / 10)).$((need_cpu10 % 10))"
  if [ $((cores * 10)) -lt "$need_cpu10" ]; then
    pf_fail "This host has $cores CPU cores but the selected modules ($SELECTED_MODULES) need $need_cores_disp. Deselect modules (e.g. scan) or use a larger host."
    return 1
  fi
  pf_pass "CPU: $cores cores available, $need_cores_disp required for: $SELECTED_MODULES"

  if [ "$mem_avail_mb" -lt "$need_mem" ]; then
    pf_fail "Only ${mem_avail_mb} MB of memory is available but the selected modules need ${need_mem} MB free. On a shared Vibe host, stop unneeded services, add RAM, or deselect modules."
    return 1
  fi
  pf_pass "Memory: ${mem_avail_mb} MB available, ${need_mem} MB required"

  # --- Disk: agents × retention with 30% headroom -------------------------
  # hot(30d, full size) + warm(retention, compressed) + base, × 1.3 headroom
  local hot_days=30
  local daily_bytes hot_gb warm_gb need_disk_gb
  daily_bytes=$((agents * EVENTS_PER_AGENT_PER_DAY * BYTES_PER_EVENT))
  hot_gb=$((daily_bytes * hot_days / 1024 / 1024 / 1024 + 1))
  warm_gb=$((daily_bytes * retention_days / WARM_COMPRESSION_RATIO / 1024 / 1024 / 1024 + 1))
  need_disk_gb=$(( (BASE_DISK_GB + hot_gb + warm_gb) * 13 / 10 ))

  local data_dir="/var/lib" free_gb
  free_gb="$(df -BG --output=avail "$data_dir" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [ -z "$free_gb" ]; then
    pf_fail "Could not measure free disk space on $data_dir."
    return 1
  fi
  if [ "$free_gb" -lt "$need_disk_gb" ]; then
    pf_fail "Disk: ${free_gb} GB free on $data_dir but ~${need_disk_gb} GB is needed for $agents agents × ${retention_days}d warm retention (30d hot + warm + 30% headroom). Add disk, lower the retention, or reduce the agent estimate if it was wrong."
    return 1
  fi
  pf_pass "Disk: ${free_gb} GB free, ~${need_disk_gb} GB required ($agents agents, ${retention_days}d warm retention, 30% headroom)"
  return 0
}
