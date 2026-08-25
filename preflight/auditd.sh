#!/usr/bin/env bash
# preflight/auditd.sh — auditd installed and no other process is consuming the
# kernel audit netlink socket (only one consumer can own it — plan §2.6).
# shellcheck shell=bash

preflight_auditd() {
  if ! command -v auditctl >/dev/null 2>&1; then
    pf_fail "auditd is not installed. Sentinel's host-integrity monitoring (privileged commands, identity file changes) depends on it. Install with: apt-get install -y auditd audispd-plugins, then re-run."
    return 1
  fi

  if ! systemctl is-active --quiet auditd; then
    log "auditd installed but not running — starting it."
    if ! systemctl enable --now auditd >/dev/null 2>&1; then
      pf_fail "auditd is installed but could not be started. Check: journalctl -u auditd"
      return 1
    fi
  fi

  # The audit netlink socket has exactly one consumer. If the registered PID
  # is not auditd, another agent (go-audit, laurel, another EDR) owns it and
  # Wazuh would receive nothing.
  local audit_pid auditd_pid
  audit_pid="$(auditctl -s 2>/dev/null | awk '/^pid/ {print $2}')"
  auditd_pid="$(systemctl show -p MainPID --value auditd 2>/dev/null)"
  if [ -n "$audit_pid" ] && [ "$audit_pid" != "0" ] && [ "$audit_pid" != "$auditd_pid" ]; then
    local owner
    owner="$(ps -o comm= -p "$audit_pid" 2>/dev/null || echo "pid $audit_pid")"
    pf_fail "Another audit consumer ('$owner', pid $audit_pid) owns the kernel audit socket instead of auditd. Only one consumer is possible — remove or reconfigure that agent (common culprits: go-audit, laurel, another EDR), then re-run."
    return 1
  fi

  pf_pass "auditd is installed, running, and is the sole kernel audit consumer."
  return 0
}
