#!/usr/bin/env bash
# wizard/wizard.sh — interactive firm-profile wizard (plain bash read/select;
# no dialog dependency). Collects every §2.6 firm-supplied input plus module
# selection and writes /etc/vibe-sentinel/config.json (600).
#
# Sourced by install.sh; entry point: run_wizard
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Prompt helpers
# ---------------------------------------------------------------------------
ask() { # var-name "Prompt" [default]
  local __var="$1" __prompt="$2" __default="${3:-}" __val
  while true; do
    if [ -n "$__default" ]; then
      read -r -p "$__prompt [$__default]: " __val
      __val="${__val:-$__default}"
    else
      read -r -p "$__prompt: " __val
    fi
    [ -n "$__val" ] && break
    echo "  A value is required."
  done
  printf -v "$__var" '%s' "$__val"
}

ask_optional() { # var-name "Prompt" [default]
  local __var="$1" __prompt="$2" __default="${3:-}" __val
  read -r -p "$__prompt${__default:+ [$__default]}: " __val
  printf -v "$__var" '%s' "${__val:-$__default}"
}

ask_secret() { # var-name "Prompt"
  local __var="$1" __val
  while true; do
    read -r -s -p "$2: " __val; echo
    [ -n "$__val" ] && break
    echo "  A value is required."
  done
  printf -v "$__var" '%s' "$__val"
}

ask_yesno() { # "Prompt" default(y|n) -> returns 0 for yes
  local ans default="${2:-n}"
  read -r -p "$1 [$( [ "$default" = y ] && echo Y/n || echo y/N )]: " ans
  ans="${ans:-$default}"
  case "$ans" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

ask_choice() { # var-name "Prompt" option1 option2 ...
  local __var="$1" __prompt="$2"; shift 2
  echo "$__prompt"
  local opt
  select opt in "$@"; do
    if [ -n "$opt" ]; then printf -v "$__var" '%s' "$opt"; break; fi
    echo "  Pick a number from the list."
  done
}

hr() { printf '%s\n' "--------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
run_wizard() {
  hr
  echo "Vibe Sentinel — Firm Setup Wizard"
  echo "Everything asked here is required for a first-time-right install (§2.6)."
  echo "Nothing is pulled or started until preflight passes on these answers."
  hr

  # ---- Firm identity ------------------------------------------------------
  local firm_name firm_state qi_name qi_email consumer_count agent_count timezone
  ask firm_name      "Firm legal name"
  ask firm_state     "Firm home state (2-letter, e.g. MO)"
  ask qi_name        "Qualified Individual (QI) full name"
  ask qi_email       "QI email address"
  ask consumer_count "Estimated number of consumers whose information the firm maintains (drives the 314.6 exemption computation)" "1000"
  ask agent_count    "How many endpoints (servers + workstations) will run a Sentinel agent? (drives disk sizing)" "10"
  ask_optional timezone "Firm timezone (IANA)" "America/Chicago"

  # ---- Domain + Cloudflare ------------------------------------------------
  hr
  echo "Sentinel publishes its hostnames under a domain on Cloudflare"
  echo "(the firm's own, or a Kisaes-provided <firm>.vibesentinel.app subzone)."
  local domain cf_token
  ask domain "Firm domain on Cloudflare (e.g. example-cpa.com)"
  echo "Create an API token with: Zone DNS:Edit, Cloudflare Tunnel:Edit,"
  echo "Access Apps and Policies:Edit, Zone WAF:Edit, Zone Settings:Edit."
  ask_secret cf_token "Cloudflare API token (input hidden)"

  # ---- SMTP ---------------------------------------------------------------
  hr
  echo "SMTP relay — required for Vaultwarden invites, Authentik enrollment,"
  echo "and email alerts. A test message will be sent during preflight."
  local smtp_host smtp_port smtp_user smtp_pass smtp_from
  ask smtp_host "SMTP host"
  ask smtp_port "SMTP port" "587"
  ask_optional smtp_user "SMTP username (blank if unauthenticated relay)"
  smtp_pass=""
  [ -n "$smtp_user" ] && ask_secret smtp_pass "SMTP password (input hidden)"
  ask_optional smtp_from "From address" "sentinel@$domain"

  # ---- Operational windows and geography ---------------------------------
  hr
  local staff_countries business_hours backup_window maint_window onsite_subnets
  ask staff_countries "Staff countries (comma-separated ISO codes; used for geo alerting)" "US"
  ask business_hours  "Business hours (local, HH:MM-HH:MM)" "08:00-18:00"
  ask backup_window   "Backup window (HH:MM-HH:MM; backup activity inside it is not alerted)" "01:00-03:00"
  ask maint_window    "Maintenance window (e.g. Sun 22:00-24:00)" "Sun 22:00-24:00"
  echo "On-site subnets define which print jobs release immediately with no PIN"
  echo "(Decision 26 — off-site mesh jobs are held for PIN/web release)."
  ask onsite_subnets  "Firm on-premises subnets (comma-separated CIDRs)" "192.168.1.0/24"

  # ---- Module selection ---------------------------------------------------
  hr
  echo "Module selection. core is required. runtime/edge/mesh/keys/pulse/print"
  echo "default ON; scan defaults OFF; ai defaults to local inference."
  local modules="core" comp_controls="{}"
  local m desc default
  for m in runtime edge mesh keys pulse print scan; do
    case "$m" in
      runtime) desc="Falco container runtime detection";        default=y ;;
      edge)    desc="CrowdSec + firewall/Cloudflare bouncers";  default=y ;;
      mesh)    desc="NetBird private network (Security Six #6)"; default=y ;;
      keys)    desc="Vaultwarden password manager (Security Six)"; default=y ;;
      pulse)   desc="Uptime Kuma availability monitoring (Security Six)"; default=y ;;
      print)   desc="Vibe Print gateway (REQ-063 paper controls)"; default=y ;;
      scan)    desc="Greenbone vulnerability scanner (optional, heavy: 2c/4GB)"; default=n ;;
    esac
    if ask_yesno "Enable module '$m' — $desc?" "$default"; then
      modules="$modules $m"
    else
      case " $SECURITY_SIX_MODULES " in
        *" $m "*)
          # Disabling a Security Six control requires a recorded compensating
          # control so the scorecard still has an answer (plan §2.5).
          echo "  '$m' is a Security Six control. Disabling it requires recording"
          echo "  the compensating control the firm uses instead"
          echo "  (e.g. \"firm uses Tailscale\", \"firm uses 1Password Business\")."
          local cc=""
          while [ -z "$cc" ]; do
            read -r -p "  Compensating control for '$m': " cc
          done
          comp_controls="$(printf '%s' "$comp_controls" | jq --arg m "$m" --arg c "$cc" '. + {($m): $c}')"
          ;;
      esac
    fi
  done
  modules="$modules ai"

  # ---- AI mode ------------------------------------------------------------
  hr
  local ai_mode="local"
  echo "AI summarization runs locally (vibellm via Vibe AI Router) by default."
  echo "Cloud Anthropic is opt-in, receives alert METADATA only (never raw"
  echo "events), and every call is written to the §7216 disclosure log."
  if ask_yesno "Enable OPTIONAL cloud Anthropic summarization (metadata only, logged as disclosure)?" n; then
    ai_mode="cloud_optin"
  fi

  # ---- Vaultwarden mode (only if keys enabled) ----------------------------
  local vw_mode="tunnel"
  if printf '%s' "$modules" | grep -qw keys; then
    hr
    echo "Vaultwarden publishing mode (§2.2 Decision):"
    echo "  tunnel    — published through the Cloudflare Tunnel WITHOUT an Access"
    echo "              login on client paths (Bitwarden apps cannot complete one);"
    echo "              protected by enforced 2FA, Cloudflare WAF + rate limits on"
    echo "              /identity/connect/token and /api/accounts/prelogin,"
    echo "              CrowdSec, and an Access policy on /admin only."
    echo "              This is the normal self-hosted Bitwarden posture — pick it"
    echo "              so phones and home machines work without the mesh client."
    echo "  mesh_only — no public hostname; every device (including phones) runs"
    echo "              the NetBird client."
    ask_choice vw_mode "Choose the Vaultwarden mode (recorded on the firm record and in the risk assessment):" tunnel mesh_only
  fi

  # ---- External port-check choice (Decision 13) ---------------------------
  hr
  echo "Daily external exposed-port check (SENT-E-005) — choose who probes:"
  echo "  kisaes-prober-optin — Kisaes-hosted prober. Opt-in; your consent is"
  echo "                        logged and Kisaes is recorded as a service"
  echo "                        provider in the firm's §314.4(f) register."
  echo "  self-worker         — a Cloudflare Worker the firm deploys from a"
  echo "                        one-click template into its OWN account."
  local portcheck
  ask_choice portcheck "External port-check method:" kisaes-prober-optin self-worker

  # ---- NetBird relay stance (informational; stays OFF) --------------------
  if printf '%s' "$modules" | grep -qw mesh; then
    hr
    echo "NetBird relay: Sentinel ships DIRECT-ONLY — zero inbound ports."
    echo "The relay (one UDP port, 3478) is NOT enabled now. It can be enabled"
    echo "later ONLY after an enrolling peer fails the NAT reachability test"
    echo "AND the QI consents; enabling it is a logged, QI-approved change,"
    echo "recorded in the risk assessment and watched by CrowdSec (Decision 17)."
    echo "No action needed — this is stated here so the choice is informed."
  fi

  # ---- Retention ----------------------------------------------------------
  hr
  local archive_years
  ask archive_years "Cold archive retention in years (3 default; firms may align to 7-year tax retention)" "3"

  # ---- Write config -------------------------------------------------------
  mkdir -p "$SENTINEL_ETC"
  local staff_countries_json onsite_json
  staff_countries_json="$(printf '%s' "$staff_countries" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"") | ascii_upcase)')"
  onsite_json="$(printf '%s' "$onsite_subnets" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')"

  ( umask 077
    jq -n \
      --arg firm_name "$firm_name" \
      --arg firm_state "$firm_state" \
      --arg qi_name "$qi_name" \
      --arg qi_email "$qi_email" \
      --argjson consumer_count "$consumer_count" \
      --argjson agent_count "$agent_count" \
      --arg timezone "$timezone" \
      --arg domain "$domain" \
      --arg cf_token "$cf_token" \
      --arg smtp_host "$smtp_host" \
      --arg smtp_port "$smtp_port" \
      --arg smtp_user "$smtp_user" \
      --arg smtp_pass "$smtp_pass" \
      --arg smtp_from "$smtp_from" \
      --argjson staff_countries "$staff_countries_json" \
      --arg business_hours "$business_hours" \
      --arg backup_window "$backup_window" \
      --arg maint_window "$maint_window" \
      --argjson onsite_subnets "$onsite_json" \
      --arg onsite_csv "$onsite_subnets" \
      --arg modules "$modules" \
      --argjson comp_controls "$comp_controls" \
      --arg ai_mode "$ai_mode" \
      --arg vw_mode "$vw_mode" \
      --arg portcheck "$portcheck" \
      --argjson archive_years "$archive_years" \
      '{
        schema_version: 1,
        generated_at: (now | todate),
        firm: {
          legal_name: $firm_name,
          state: $firm_state,
          qi_name: $qi_name,
          qi_email: $qi_email,
          consumer_count_estimate: $consumer_count,
          agent_count_estimate: $agent_count,
          timezone: $timezone,
          domain: $domain,
          staff_countries: $staff_countries,
          business_hours: $business_hours,
          backup_window: $backup_window,
          maintenance_window: $maint_window,
          onsite_subnets: $onsite_subnets,
          onsite_subnets_csv: $onsite_csv
        },
        cloudflare: { api_token: $cf_token },
        smtp: {
          host: $smtp_host, port: $smtp_port, username: $smtp_user,
          password: $smtp_pass, from: $smtp_from
        },
        modules: {
          selected: ($modules | split(" ")),
          compensating_controls: $comp_controls,
          ai:   { mode: $ai_mode },
          keys: { vaultwarden_mode: $vw_mode, events_days_retain: 1095 },
          mesh: {
            relay_enabled: false,
            relay_note: "Direct-only by default. Enable only after a failed NAT test with QI consent (Decision 17); enabling is a logged, QI-approved change recorded in the risk assessment."
          }
        },
        external_port_check: { method: $portcheck, consented_at: (now | todate) },
        retention: { hot_days: 30, warm_days: 365, archive_years: $archive_years },
        backup: { restic_repository: "/var/lib/vibe-sentinel/restic-repo" },
        network: { mesh_bind_ip: "127.0.0.1" },
        preflight: { falco_privileged_fallback: false }
      }' >"$SENTINEL_CONFIG"
  )
  chmod 600 "$SENTINEL_CONFIG"
  log_ok "Firm configuration written to $SENTINEL_CONFIG (mode 600)"

  SELECTED_MODULES="$modules"
  export SELECTED_MODULES
}
