#!/usr/bin/env bash
# lib/cloudflare.sh — Cloudflare provisioning: DNS records per §2.6, tunnel
# creation + ingress (http2Origin for NetBird gRPC), Access applications and
# machine-endpoint BYPASS policies per §2.2, and the zone gRPC setting.
# shellcheck shell=bash

CF_API="https://api.cloudflare.com/client/v4"

cf_token() { secret_value cf_api_token; }

cf_api_call() { # METHOD path [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --max-time 30 -X "$method" "$CF_API$path"
              -H "Authorization: Bearer $(cf_token)"
              -H "Content-Type: application/json")
  [ -n "$body" ] && args+=(--data "$body")
  curl "${args[@]}"
}

cf_ok() { jq -e '.success == true' >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Zone / account discovery
# ---------------------------------------------------------------------------
cf_discover_zone() { # domain -> exports CF_ZONE_ID CF_ACCOUNT_ID
  local domain="$1" resp
  resp="$(cf_api_call GET "/zones?name=${domain}&status=active")"
  CF_ZONE_ID="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  CF_ACCOUNT_ID="$(printf '%s' "$resp" | jq -r '.result[0].account.id // empty')"
  [ -n "$CF_ZONE_ID" ] || die "Cloudflare zone for '$domain' not found or not active." \
    "Add the domain to Cloudflare (or use a Kisaes-provided <firm>.vibesentinel.app subzone) and re-run."
  export CF_ZONE_ID CF_ACCOUNT_ID
}

# ---------------------------------------------------------------------------
# DNS records
# ---------------------------------------------------------------------------
cf_ensure_dns_record() { # name(fqdn) type content proxied(true|false)
  local name="$1" type="$2" content="$3" proxied="$4" existing id resp
  existing="$(cf_api_call GET "/zones/$CF_ZONE_ID/dns_records?name=${name}&type=${type}")"
  id="$(printf '%s' "$existing" | jq -r '.result[0].id // empty')"
  local body
  body="$(jq -n --arg n "$name" --arg t "$type" --arg c "$content" --argjson p "$proxied" \
          '{name:$n, type:$t, content:$c, proxied:$p, ttl:1, comment:"managed by vibe-sentinel-installer"}')"
  if [ -n "$id" ]; then
    resp="$(cf_api_call PUT "/zones/$CF_ZONE_ID/dns_records/$id" "$body")"
  else
    resp="$(cf_api_call POST "/zones/$CF_ZONE_ID/dns_records" "$body")"
  fi
  printf '%s' "$resp" | cf_ok || die "Failed to create DNS record $name ($type)." \
    "Check the API token has Zone:DNS:Edit on this zone. Response: $(printf '%s' "$resp" | jq -c '.errors')"
  log_ok "DNS: $name $type → $content (proxied=$proxied)"
}

# §2.6 hostname list. Tunnel-published names → proxied CNAME to the tunnel;
# mesh-only names (print., ntfy., vault. in mesh_only mode) → unproxied A
# records pointing at the mesh IP (private IPs in public DNS are allowed).
cf_provision_hostnames() { # tunnel-id mesh-ip vaultwarden-mode(tunnel|mesh_only)
  local tunnel_id="$1" mesh_ip="$2" vw_mode="$3"
  local domain tunnel_cname
  domain="$(config_get '.firm.domain')"
  tunnel_cname="${tunnel_id}.cfargotunnel.com"

  local h
  for h in sentinel wazuh id nb nb-signal nb-admin status; do
    cf_ensure_dns_record "$h.$domain" CNAME "$tunnel_cname" true
  done
  if [ "$vw_mode" = "mesh_only" ]; then
    cf_ensure_dns_record "vault.$domain" A "$mesh_ip" false
  else
    cf_ensure_dns_record "vault.$domain" CNAME "$tunnel_cname" true
  fi
  # Always mesh-only (plan §2.6): print., ntfy.
  cf_ensure_dns_record "print.$domain" A "$mesh_ip" false
  cf_ensure_dns_record "ntfy.$domain" A "$mesh_ip" false
}

# ---------------------------------------------------------------------------
# Tunnel
# ---------------------------------------------------------------------------
cf_ensure_tunnel() { # name -> echoes tunnel id; stores credentials secret
  local name="$1" resp id secret
  resp="$(cf_api_call GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?name=${name}&is_deleted=false")"
  id="$(printf '%s' "$resp" | jq -r '.result[0].id // empty')"
  if [ -z "$id" ]; then
    secret="$(openssl rand -base64 32)"
    resp="$(cf_api_call POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
      "$(jq -n --arg n "$name" --arg s "$secret" '{name:$n, tunnel_secret:$s, config_src:"cloudflare"}')")"
    printf '%s' "$resp" | cf_ok || die "Failed to create Cloudflare tunnel '$name'." \
      "Check the API token has Cloudflare Tunnel:Edit. Response: $(printf '%s' "$resp" | jq -c '.errors')"
    id="$(printf '%s' "$resp" | jq -r '.result.id')"
    ( umask 077; printf '%s' "$secret" >"$SECRETS_DIR/tunnel_secret" )
    log_ok "Tunnel created: $name ($id)"
  else
    log_ok "Tunnel already exists: $name ($id)"
  fi
  # Token for cloudflared
  resp="$(cf_api_call GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$id/token")"
  ( umask 077; printf '%s' "$resp" | jq -r '.result' >"$SECRETS_DIR/tunnel_token" )
  printf '%s' "$id"
}

# Push the remote-managed tunnel ingress. NetBird management/signal are gRPC:
# their ingress entries set originRequest.http2Origin=true (plan §2.2 item 1).
cf_configure_tunnel_ingress() { # tunnel-id vaultwarden-mode
  local tunnel_id="$1" vw_mode="$2" domain body resp
  domain="$(config_get '.firm.domain')"
  body="$(jq -n --arg d "$domain" --arg vw "$vw_mode" '{
    config: { ingress: (
      [
        {hostname:("sentinel." + $d),  service:"http://sentinel-web:8080"},
        {hostname:("wazuh." + $d),     service:"https://wazuh-dashboard:5601", originRequest:{noTLSVerify:true}},
        {hostname:("id." + $d),        service:"http://authentik-server:9000"},
        {hostname:("nb." + $d),        service:"http://netbird-management:80",  originRequest:{http2Origin:true}},
        {hostname:("nb-signal." + $d), service:"http://netbird-signal:80",      originRequest:{http2Origin:true}},
        {hostname:("nb-admin." + $d),  service:"http://netbird-dashboard:80"},
        {hostname:("status." + $d),    service:"http://uptime-kuma:3001"}
      ]
      + (if $vw == "tunnel" then [{hostname:("vault." + $d), service:"http://vaultwarden:80"}] else [] end)
      + [{service:"http_status:404"}]
    )}
  }')"
  resp="$(cf_api_call PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" "$body")"
  printf '%s' "$resp" | cf_ok || die "Failed to push tunnel ingress configuration." \
    "Response: $(printf '%s' "$resp" | jq -c '.errors')"
  log_ok "Tunnel ingress configured (http2Origin=true on nb./nb-signal. for gRPC)"
}

# ---------------------------------------------------------------------------
# Zone gRPC setting — required for NetBird management/signal through the proxy.
# ---------------------------------------------------------------------------
cf_enable_grpc() {
  local resp
  resp="$(cf_api_call PATCH "/zones/$CF_ZONE_ID/settings/grpc" '{"value":"on"}')"
  printf '%s' "$resp" | cf_ok || die "Failed to enable gRPC proxying on the zone." \
    "The API token needs Zone Settings:Edit. NetBird management/signal will not work without it."
  log_ok "Zone gRPC proxying: on"
}

# ---------------------------------------------------------------------------
# Access applications and policies
# ---------------------------------------------------------------------------
cf_find_access_app() { # domain-pattern -> id or empty
  cf_api_call GET "/accounts/$CF_ACCOUNT_ID/access/apps?per_page=100" \
    | jq -r --arg d "$1" '.result[]? | select(.domain == $d) | .id' | head -n1
}

cf_ensure_access_app() { # name domain-pattern session-duration -> echoes app id
  local name="$1" pattern="$2" session="${3:-24h}" id body resp
  id="$(cf_find_access_app "$pattern")"
  body="$(jq -n --arg n "$name" --arg d "$pattern" --arg s "$session" \
    '{name:$n, domain:$d, type:"self_hosted", session_duration:$s, app_launcher_visible:false}')"
  if [ -n "$id" ]; then
    resp="$(cf_api_call PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$id" "$body")"
  else
    resp="$(cf_api_call POST "/accounts/$CF_ACCOUNT_ID/access/apps" "$body")"
    id="$(printf '%s' "$resp" | jq -r '.result.id // empty')"
  fi
  printf '%s' "$resp" | cf_ok || die "Failed to create Access application '$name' for $pattern." \
    "The API token needs Access: Apps and Policies:Edit. Response: $(printf '%s' "$resp" | jq -c '.errors')"
  printf '%s' "$id"
}

cf_ensure_access_policy() { # app-id name decision(allow|bypass) include-json
  local app_id="$1" name="$2" decision="$3" include="$4" resp body existing pid
  existing="$(cf_api_call GET "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies")"
  pid="$(printf '%s' "$existing" | jq -r --arg n "$name" '.result[]? | select(.name == $n) | .id' | head -n1)"
  body="$(jq -n --arg n "$name" --arg d "$decision" --argjson inc "$include" \
    '{name:$n, decision:$d, include:$inc, precedence:1}')"
  if [ -n "$pid" ]; then
    resp="$(cf_api_call PUT "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies/$pid" "$body")"
  else
    resp="$(cf_api_call POST "/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" "$body")"
  fi
  printf '%s' "$resp" | cf_ok || die "Failed to set Access policy '$name'." \
    "Response: $(printf '%s' "$resp" | jq -c '.errors')"
  log_ok "Access policy: $name ($decision)"
}

# Human-facing apps: Access ALLOW policy restricted to firm emails (MFA is
# enforced in the Cloudflare Access identity provider configuration).
cf_protect_dashboard() { # name hostname email-domain
  local app_id
  app_id="$(cf_ensure_access_app "$1" "$2")"
  cf_ensure_access_policy "$app_id" "firm-staff-allow" "allow" \
    "$(jq -n --arg d "$3" '[{email_domain:{domain:$d}}]')"
}

# Machine-facing endpoints get BYPASS (everyone) per §2.2 — peers and clients
# must reach them before they are on the mesh, and NetBird/Bitwarden clients
# cannot complete an interactive Access login. CrowdSec + WAF rate limiting
# stand in front of them. Changing this list raises SENT-V-SENT-001.
cf_bypass_machine_endpoint() { # name pattern
  local app_id
  app_id="$(cf_ensure_access_app "$1" "$2")"
  cf_ensure_access_policy "$app_id" "machine-endpoint-bypass" "bypass" \
    "$(jq -n '[{everyone:{}}]')"
}
