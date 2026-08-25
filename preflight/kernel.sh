#!/usr/bin/env bash
# preflight/kernel.sh — kernel ≥ 5.8 with BTF for the Falco modern eBPF probe.
# Older kernels are not fatal: the installer falls back to Falco privileged
# mode and records that as a risk item in the config (plan §2.2 / §2.6).
# shellcheck shell=bash

preflight_kernel() {
  local kver
  kver="$(uname -r | cut -d- -f1)"
  local btf_ok=1
  [ -r /sys/kernel/btf/vmlinux ] && btf_ok=0

  if version_ge "$kver" "5.8" && [ "$btf_ok" -eq 0 ]; then
    pf_pass "Kernel $kver with BTF (/sys/kernel/btf/vmlinux) — Falco will run with the modern eBPF probe and minimum capabilities, not privileged."
    export FALCO_PRIVILEGED_FALLBACK=false
    return 0
  fi

  if ! version_ge "$kver" "5.8"; then
    pf_warn "Kernel $kver is older than 5.8 — the Falco modern eBPF probe is unavailable."
  else
    pf_warn "Kernel $kver has no BTF (/sys/kernel/btf/vmlinux missing) — the Falco modern eBPF probe is unavailable."
  fi
  pf_warn "Falling back to Falco privileged mode. This is recorded as a risk item; upgrading to a BTF-enabled kernel (any stock Ubuntu 22.04+/Debian 12 kernel has it) removes it."
  export FALCO_PRIVILEGED_FALLBACK=true
  record_risk "RISK-FALCO-PRIVILEGED" \
    "Falco running privileged (no BTF kernel)" \
    "Kernel $(uname -r) lacks BTF; Falco was deployed with --privileged instead of the minimum capability set (CAP_BPF/CAP_PERFMON/CAP_SYS_RESOURCE/CAP_SYS_PTRACE). Upgrade the kernel and re-run the installer to remove this exposure."
  return 0
}
