#!/usr/bin/env bash
# modules/keys/tunnel-mode-setup.sh — the §2.2 Vaultwarden TUNNEL-mode posture.
#
# In tunnel mode vault.<domain> is published through the Cloudflare Tunnel
# WITHOUT an Access login on the client paths: the Bitwarden desktop, browser
# extension, and mobile apps cannot complete an interactive Access login. What
# stands in for it, and what this script creates:
#
#   1. Cloudflare rate-limit rules on the two endpoints an attacker actually
#      hammers — /identity/connect/token (credential stuffing) and
#      /api/accounts/prelogin (account enumeration / KDF probing).
#   2. A Cloudflare Access policy on the /admin path ONLY. The rest of the
#      hostname stays open to the clients; /admin is staff-only and is in any
#      case disabled at rest (ADMIN_TOKEN unset — see maintenance-mode.sh).
#
# The remaining layers are configured elsewhere and are named here so the
# posture is legible in one place: Vaultwarden's own auth with enforced 2FA
# (org policy, Phase 7K bootstrap), Cloudflare WAF managed rules (zone-level),
# and CrowdSec parsing the Vaultwarden logs with the Cloudflare bouncer
# (modules/edge). The harness verifies that an unauthenticated request to
# /admin is challenged.
#
# Idempotent: safe to re-run on every install and upgrade.
set -euo pipefail

SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
INSTALLER_ROOT="${INSTALLER_ROOT:-/opt/vibe-sentinel-installer}"
[ -f "$INSTALLER_ROOT/lib/common.sh" ] || INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/vibe-sentinel-installer"
# shellcheck source=../../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"
# shellcheck source=../../lib/secrets.sh
. "$INSTALLER_ROOT/lib/secrets.sh"
# shellcheck source=../../lib/cloudflare.sh
. "$INSTALLER_ROOT/lib/cloudflare.sh"

DOMAIN="$(config_get '.firm.domain')"
VW_MODE="$(config_get '.modules.keys.vaultwarden_mode' 'tunnel')"
VW_HOST="vault.$DOMAIN"

if [ "$VW_MODE" != "tunnel" ]; then
  log "Vaultwarden is in '$VW_MODE' mode — no Cloudflare edge rules needed (no public hostname). Nothing to do."
  exit 0
fi

cf_discover_zone "$DOMAIN"

# ---------------------------------------------------------------------------
# 1. Rate limiting on the two client-auth endpoints.
#
# Written into the zone's http_ratelimit ruleset entrypoint. Existing rules the
# firm added are preserved; ours are identified by their description prefix so
# a re-run replaces rather than duplicates them, and uninstall.sh can find them.
# ---------------------------------------------------------------------------
RULE_PREFIX="vibe-sentinel: vaultwarden"

vw_ratelimit_rule() { # description path requests period mitigation
  jq -n --arg d "$1" --arg host "$VW_HOST" --arg path "$2" \
        --argjson req "$3" --argjson period "$4" --argjson timeout "$5" '{
    description: $d,
    expression: ("(http.host eq \"" + $host + "\" and http.request.uri.path eq \"" + $path + "\")"),
    action: "block",
    ratelimit: {
      characteristics: ["ip.src", "cf.colo.id"],
      period: $period,
      requests_per_period: $req,
      mitigation_timeout: $timeout,
      counting_expression: ""
    },
    enabled: true
  }'
}

# Token endpoint: a legitimate client logs in a handful of times a minute; 10
# per minute per IP is generous and still stops credential stuffing cold.
TOKEN_RULE="$(vw_ratelimit_rule "$RULE_PREFIX token endpoint (credential stuffing)" \
  "/identity/connect/token" 10 60 600)"
# Prelogin leaks whether an address is a user and what KDF it uses; 20/min is
# more than any real client needs.
PRELOGIN_RULE="$(vw_ratelimit_rule "$RULE_PREFIX prelogin endpoint (account enumeration)" \
  "/api/accounts/prelogin" 20 60 600)"

RS_RESP="$(cf_api_call GET "/zones/$CF_ZONE_ID/rulesets?phase=http_ratelimit")"
RS_ID="$(printf '%s' "$RS_RESP" | jq -r '.result[]? | select(.phase=="http_ratelimit" and .kind=="zone") | .id' | head -n1)"

if [ -n "${RS_ID:-}" ]; then
  EXISTING="$(cf_api_call GET "/zones/$CF_ZONE_ID/rulesets/$RS_ID" \
    | jq --arg p "$RULE_PREFIX" '[.result.rules[]? | select((.description // "") | startswith($p) | not)]')"
else
  EXISTING='[]'
fi
[ "$EXISTING" = "null" ] && EXISTING='[]'

BODY="$(jq -n --argjson keep "$EXISTING" --argjson a "$TOKEN_RULE" --argjson b "$PRELOGIN_RULE" \
  '{name:"http_ratelimit", kind:"zone", phase:"http_ratelimit", rules: ($keep + [$a, $b])}')"

RESP="$(cf_api_call PUT "/zones/$CF_ZONE_ID/rulesets/phases/http_ratelimit/entrypoint" "$BODY")"
if printf '%s' "$RESP" | cf_ok; then
  log_ok "Cloudflare rate limiting on $VW_HOST: /identity/connect/token 10/min, /api/accounts/prelogin 20/min (10-minute block)"
else
  die "Failed to create the Vaultwarden rate-limit rules on $VW_HOST." \
      "The API token needs Zone:WAF/Rate Limit:Edit (a rate-limiting ruleset also requires a plan that supports it). Without these rules the token endpoint is unprotected — either fix the token scope and re-run this script, or switch Vaultwarden to mesh_only mode. Response: $(printf '%s' "$RESP" | jq -c '.errors')"
fi

# ---------------------------------------------------------------------------
# 2. Access policy on the /admin path ONLY.
#
# Deliberately NOT on vault.<domain> itself — an Access login there would lock
# out every Bitwarden client. If an operator ever adds one, this is the place
# it would show up, so we check and refuse to leave it silently in place.
# ---------------------------------------------------------------------------
cf_protect_dashboard "Vaultwarden Admin (/admin only)" "$VW_HOST/admin*" "$DOMAIN"
log_ok "Access policy applied to $VW_HOST/admin* only; client paths stay open to Bitwarden apps."

ROOT_APP="$(cf_find_access_app "$VW_HOST")"
if [ -n "${ROOT_APP:-}" ]; then
  record_risk "SENT-K-ACCESS-ROOT" \
    "Cloudflare Access application covers the whole Vaultwarden hostname" \
    "An Access application exists for $VW_HOST (id $ROOT_APP). Bitwarden desktop, browser, and mobile clients cannot complete an interactive Access login, so this will break every client. Access belongs on $VW_HOST/admin* only (§2.2)."
  log_warn "An Access application covers all of $VW_HOST — Bitwarden clients will break. Remove it; only /admin* should be protected."
fi

log_ok "Vaultwarden tunnel-mode edge posture configured for $VW_HOST."
log    "Remaining layers (configured elsewhere): enforced 2FA org policy, CF WAF managed rules, CrowdSec on the Vaultwarden logs."
log    "/admin stays disabled at rest — ADMIN_TOKEN is unset. Use maintenance-mode.sh for the 30-minute auto-reverting window."
