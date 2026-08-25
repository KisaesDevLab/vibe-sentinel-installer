#!/usr/bin/env bash
# preflight/cloudflare.sh — verifies the firm's Cloudflare API token carries
# every scope the installer needs (plan §2.6): Zone DNS edit, Tunnel edit,
# Access apps/policies edit, WAF/rate-limit edit, and the gRPC zone setting.
# Read scopes are probed with GETs; DNS *edit* is proven with a create+delete
# of a throwaway TXT record so a read-only token cannot slip through.
# shellcheck shell=bash

_cfp_call() { # METHOD path [body] — uses CFP_TOKEN
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --max-time 20 -X "$method" "https://api.cloudflare.com/client/v4$path"
              -H "Authorization: Bearer $CFP_TOKEN" -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(--data "$body")
  curl "${args[@]}" 2>/dev/null
}

_cfp_success() { jq -e '.success == true' >/dev/null 2>&1; }

preflight_cloudflare() { # uses config: .firm.domain, .cloudflare.api_token
  CFP_TOKEN="$(config_get '.cloudflare.api_token')"
  local domain
  domain="$(config_get '.firm.domain')"
  if [ -z "$CFP_TOKEN" ] || [ -z "$domain" ]; then
    pf_fail "Cloudflare token or domain missing from the wizard answers — cannot verify token scopes."
    return 1
  fi

  # 0. Token is valid at all
  if ! _cfp_call GET "/user/tokens/verify" | _cfp_success; then
    pf_fail "The Cloudflare API token is invalid or expired. Create a token at dash.cloudflare.com → My Profile → API Tokens with: Zone DNS:Edit, Cloudflare Tunnel:Edit, Access: Apps and Policies:Edit, Zone WAF:Edit, Zone Settings:Edit."
    return 1
  fi
  pf_pass "Cloudflare token is valid."

  # Zone lookup
  local zresp zone_id account_id
  zresp="$(_cfp_call GET "/zones?name=${domain}")"
  zone_id="$(printf '%s' "$zresp" | jq -r '.result[0].id // empty')"
  account_id="$(printf '%s' "$zresp" | jq -r '.result[0].account.id // empty')"
  if [ -z "$zone_id" ]; then
    pf_fail "The token cannot see a Cloudflare zone named '$domain'. Either the domain is not on Cloudflare or the token is scoped to a different zone. Fix the token's zone resources and re-run."
    return 1
  fi
  pf_pass "Zone '$domain' visible to the token (zone $zone_id)."

  local failed=0

  # 1. Zone DNS EDIT — proven by create+delete of a throwaway TXT record.
  local rec resp rec_id
  rec="_vibe-sentinel-preflight.${domain}"
  resp="$(_cfp_call POST "/zones/$zone_id/dns_records" \
    "$(jq -n --arg n "$rec" '{type:"TXT", name:$n, content:"vibe-sentinel scope probe", ttl:60}')")"
  if printf '%s' "$resp" | _cfp_success; then
    rec_id="$(printf '%s' "$resp" | jq -r '.result.id')"
    _cfp_call DELETE "/zones/$zone_id/dns_records/$rec_id" >/dev/null
    pf_pass "Scope OK: Zone DNS edit (probe TXT record created and deleted)."
  else
    pf_fail "Scope missing: Zone DNS Edit. The installer must create the §2.6 hostnames and answer ACME DNS-01 challenges. Add 'Zone → DNS → Edit' to the token."
    failed=1
  fi

  # 2. Tunnel edit — list tunnels (needs Cloudflare Tunnel read at minimum;
  #    write is exercised at install when the tunnel is created).
  if _cfp_call GET "/accounts/$account_id/cfd_tunnel?is_deleted=false&per_page=1" | _cfp_success; then
    pf_pass "Scope OK: Cloudflare Tunnel (tunnel list readable; edit verified at tunnel creation)."
  else
    pf_fail "Scope missing: Cloudflare Tunnel Edit. The dashboard, Authentik, and NetBird are published only through a tunnel. Add 'Account → Cloudflare Tunnel → Edit' to the token."
    failed=1
  fi

  # 3. Access apps/policies edit
  if _cfp_call GET "/accounts/$account_id/access/apps?per_page=1" | _cfp_success; then
    pf_pass "Scope OK: Access apps/policies (apps listable)."
  else
    pf_fail "Scope missing: Access: Apps and Policies Edit. Dashboards sit behind Access and machine endpoints need bypass policies (§2.2). Add 'Account → Access: Apps and Policies → Edit'."
    failed=1
  fi

  # 4. WAF / rate-limit edit — zone rulesets listable
  if _cfp_call GET "/zones/$zone_id/rulesets" | _cfp_success; then
    pf_pass "Scope OK: WAF/rate-limit (zone rulesets listable)."
  else
    pf_fail "Scope missing: Zone WAF Edit. Vaultwarden tunnel mode requires rate-limit rules on /identity/connect/token and /api/accounts/prelogin. Add 'Zone → Zone WAF → Edit'."
    failed=1
  fi

  # 5. gRPC zone setting — readable now, PATCHed at install
  if _cfp_call GET "/zones/$zone_id/settings/grpc" | _cfp_success; then
    pf_pass "Scope OK: zone settings (gRPC setting readable; enabled at install for NetBird)."
  else
    pf_fail "Scope missing: Zone Settings Edit. NetBird management/signal are gRPC and require the zone gRPC setting on. Add 'Zone → Zone Settings → Edit'."
    failed=1
  fi

  [ "$failed" -eq 0 ] && return 0
  return 1
}
