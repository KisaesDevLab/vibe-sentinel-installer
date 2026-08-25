#!/usr/bin/env bash
# preflight/timesync.sh — active time synchronization (systemd-timesyncd or
# chrony). Log integrity and the FTC 30-day clock both depend on true time.
# shellcheck shell=bash

preflight_timesync() {
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active --quiet chrony 2>/dev/null; then
    if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
      pf_pass "Time sync active via chrony."
      return 0
    fi
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
      pf_pass "Time sync active via systemd-timesyncd (NTPSynchronized=yes)."
      return 0
    fi
    # Not synchronized — try enabling timesyncd before failing.
    log "Clock not NTP-synchronized — enabling systemd-timesyncd."
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp true >/dev/null 2>&1 || true
    sleep 5
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
      pf_pass "systemd-timesyncd enabled; clock is now synchronized."
      return 0
    fi
  fi

  pf_fail "No active time synchronization found. Alert timestamps, log integrity (SENT-H-008), and breach-notification deadlines all depend on a correct clock. Enable one: 'timedatectl set-ntp true' or 'apt-get install -y chrony && systemctl enable --now chrony', then re-run."
  return 1
}
