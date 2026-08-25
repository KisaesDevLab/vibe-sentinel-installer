#!/usr/bin/env bash
# preflight/dns.sh — the firm domain must resolve via Cloudflare nameservers
# and this host must be able to resolve public DNS at all (ACME DNS-01,
# tunnel bootstrap, and the mesh-hostname plan in §2.6 all depend on it).
# shellcheck shell=bash

_dns_lookup_ns() { # domain
  if command -v dig >/dev/null 2>&1; then
    dig +short NS "$1" 2>/dev/null
  else
    # busybox/glibc fallback
    getent hosts "$1" >/dev/null 2>&1 && echo "resolved-no-ns-info"
  fi
}

preflight_dns() {
  local domain
  domain="$(config_get '.firm.domain')"
  if [ -z "$domain" ]; then
    pf_fail "No firm domain in the wizard answers — cannot check DNS."
    return 1
  fi

  # 1. Host can resolve external names at all
  if ! getent hosts api.cloudflare.com >/dev/null 2>&1; then
    pf_fail "This host cannot resolve public DNS (api.cloudflare.com failed). Fix /etc/resolv.conf or the upstream resolver — the tunnel, ACME, and image pulls all need DNS."
    return 1
  fi
  pf_pass "Host resolves public DNS."

  # 2. Domain is delegated to Cloudflare
  local ns
  ns="$(_dns_lookup_ns "$domain")"
  if [ -z "$ns" ]; then
    pf_fail "Domain '$domain' has no resolvable NS records — is it registered and delegated? The §2.6 hostnames cannot be created on an undelegated domain."
    return 1
  fi
  if printf '%s' "$ns" | grep -qi 'cloudflare.com'; then
    pf_pass "Domain '$domain' is delegated to Cloudflare nameservers."
  elif [ "$ns" = "resolved-no-ns-info" ]; then
    pf_warn "Could not enumerate NS records (dig not installed) — Cloudflare zone visibility is verified separately by the token preflight."
  else
    pf_fail "Domain '$domain' is NOT delegated to Cloudflare (NS: $(printf '%s' "$ns" | tr '\n' ' ')). Point the domain's nameservers at the pair Cloudflare assigned in the dashboard, wait for delegation, then re-run."
    return 1
  fi
  return 0
}
