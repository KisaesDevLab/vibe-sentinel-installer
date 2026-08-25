#!/usr/bin/env bash
# modules/ai/setup.sh — the ai module ships NO container (plan §2.5). It writes
# one config file: how sentinel-api and sentinel-worker should reach a model.
#
# Default is LOCAL (vibellm / Ollama through the Vibe AI Router). Cloud
# Anthropic is opt-in per firm and, when enabled, receives ALERT AND REPORT
# METADATA ONLY — rule ids, counts, asset labels, timestamps — never raw event
# payloads, never file contents, never customer information. Every cloud call
# is written to the disclosure log (§7216 / REQ-014 evidence).
#
# If no model is reachable at all, Sentinel does not fail: the daily digest and
# weekly summary fall back to a deterministic template. Prose is a convenience;
# the numbers underneath it are generated the same way either way.
#
# Idempotent: safe to re-run on every install and upgrade.
set -euo pipefail

SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
INSTALLER_ROOT="${INSTALLER_ROOT:-/opt/vibe-sentinel-installer}"
[ -f "$INSTALLER_ROOT/lib/common.sh" ] || INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/vibe-sentinel-installer"
# shellcheck source=../../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"

AI_DIR="$SENTINEL_ETC/ai"
CLIENT_CONFIG="$AI_DIR/router-client.json"

MODE="$(config_get '.modules.ai.mode' 'local')"
ROUTER_URL="$(config_get '.modules.ai.router_url' 'http://127.0.0.1:8787')"
LOCAL_MODEL="$(config_get '.modules.ai.local_model' 'vibellm')"
CLOUD_MODEL="$(config_get '.modules.ai.cloud_model' 'claude-sonnet-4-5')"

case "$MODE" in
  local|cloud_optin) : ;;
  *) die "Unknown AI mode '$MODE'." "Valid modes are 'local' (default) and 'cloud_optin' (Decision 8). Fix .modules.ai.mode in $SENTINEL_CONFIG and re-run." ;;
esac

mkdir -p "$AI_DIR"
chmod 750 "$AI_DIR"

# The API key for cloud mode, if the firm supplied one, is a file-backed secret
# like every other credential — never inline in this config.
CLOUD_KEY_FILE="$SENTINEL_ETC/secrets/anthropic_api_key"
CLOUD_KEY_PRESENT=false
[ -s "$CLOUD_KEY_FILE" ] && CLOUD_KEY_PRESENT=true

( umask 077
  jq -n \
    --arg mode "$MODE" \
    --arg router_url "$ROUTER_URL" \
    --arg local_model "$LOCAL_MODEL" \
    --arg cloud_model "$CLOUD_MODEL" \
    --arg cloud_key_file "$CLOUD_KEY_FILE" \
    --argjson cloud_key_present "$CLOUD_KEY_PRESENT" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
      schema_version: 1,
      generated_at: $generated_at,
      generated_by: "vibe-sentinel-installer modules/ai/setup.sh",

      mode: $mode,

      router: {
        url: $router_url,
        note: "Vibe AI Router. Sentinel never talks to a model provider directly; the router is the single egress point and the single place calls are logged."
      },

      providers: {
        local: {
          enabled: true,
          kind: "vibellm",
          model: $local_model,
          default: true,
          note: "On-premises. Full alert text and event payloads may be sent here — nothing leaves the firm."
        },
        cloud: {
          enabled: ($mode == "cloud_optin"),
          kind: "anthropic",
          model: $cloud_model,
          api_key_file: $cloud_key_file,
          api_key_present: $cloud_key_present,
          payload_policy: "metadata_only",
          allowed_fields: [
            "rule_id", "rule_name", "severity", "count",
            "asset_label", "asset_class", "first_seen", "last_seen",
            "mitre_tags", "req_tags"
          ],
          forbidden_fields: [
            "raw_event", "log_line", "command_line", "file_path", "file_content",
            "username", "email", "client_name", "ssn", "ein", "ptin", "efin",
            "ip_address", "hostname"
          ],
          disclosure_log: true,
          note: "Opt-in per firm (Decision 8). Metadata only; every call is written to the disclosure log. Disabling this is a one-line change to .modules.ai.mode."
        }
      },

      fallback: {
        kind: "deterministic_template",
        note: "Used when no model is reachable. Digests and summaries still generate; only the prose is templated."
      },

      consumers: ["sentinel-api", "sentinel-worker"],
      uses: ["daily_digest", "weekly_summary", "alert_plain_english_summary", "annual_report_narrative"]
    }' >"$CLIENT_CONFIG" )
chmod 640 "$CLIENT_CONFIG"

log_ok "AI router client config written to $CLIENT_CONFIG (mode: $MODE)"

if [ "$MODE" = "local" ]; then
  log "Local mode: summarization goes to vibellm ($LOCAL_MODEL) through the Vibe AI Router at $ROUTER_URL."
  log "Nothing about this firm's alerts leaves the premises."
else
  log_warn "Cloud opt-in mode: alert and report METADATA will be sent to Anthropic ($CLOUD_MODEL)."
  log      "Sent: rule ids, counts, asset labels, timestamps. Never sent: raw events, log lines, file paths, names, or any customer information."
  log      "Every call is written to the disclosure log. This is a §7216-relevant decision and belongs in the risk assessment."
  if [ "$CLOUD_KEY_PRESENT" != "true" ]; then
    log_warn "No Anthropic API key found at $CLOUD_KEY_FILE — Sentinel will fall back to the local model, then to the deterministic template."
    log      "To enable it:  install -m 600 /dev/stdin $CLOUD_KEY_FILE  <<<'sk-ant-...'  then re-run this script."
  fi
fi

# Reachability is informational only — a missing router must never block an
# install, because the deterministic fallback keeps every report working.
if curl -fsS -o /dev/null --max-time 5 "$ROUTER_URL/healthz" 2>/dev/null; then
  log_ok "Vibe AI Router reachable at $ROUTER_URL"
else
  log_warn "Vibe AI Router not reachable at $ROUTER_URL — digests will use the deterministic template until it is."
  log      "Set .modules.ai.router_url in $SENTINEL_CONFIG if the router runs elsewhere on this host or on the mesh."
fi
