#!/usr/bin/env bash
# lite/generate-lite.sh — per-firm Sentinel Lite enrollment bundle generator
# (plan §6, Phase 7).
#
# One firm, one run, three bundles. Each bundle carries everything a workstation
# needs to enrol itself with no operator typing anything at the endpoint:
#
#   * NetBird client + a ONE-TIME, single-use setup key scoped to the
#     workstation group. Enrolled FIRST, because the Wazuh manager, the print
#     queues, and Vaultwarden all live on the mesh and are unreachable until
#     the peer is up. Getting this order wrong is the single most common way a
#     Lite install "works" and then reports nothing.
#   * Wazuh agent preconfigured with the manager's MESH hostname and the firm's
#     enrollment password.
#   * Sysmon (Windows) / auditd rules (Linux) / EndpointSecurity (macOS).
#   * The posture collector on a 4-hour schedule.
#   * Firm print queues over IPP, plus a host firewall rule blocking 9100/631/515
#     egress to everything except the gateway.
#
# The setup key is single-use and short-lived by design: a bundle that leaks is
# a bundle that has already been spent. Regenerate per batch of machines.
#
# Usage:
#   generate-lite.sh [--platform windows|macos|linux|all]
#                    [--role workstation|docker-host|db-host]
#                    [--out <dir>] [--count <n>] [--expires <hours>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="${INSTALLER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"

# The monorepo that holds the shared rule packs. The installer repo sits beside
# it in a normal Kisaes checkout; MONOREPO_ROOT overrides for CI.
MONOREPO_ROOT="${MONOREPO_ROOT:-$(cd "$INSTALLER_ROOT/.." && pwd)/Vibe-Sentinel}"
AUDITD_RULES_DIR="$MONOREPO_ROOT/packages/rules/auditd"

PLATFORM=all
ROLE=workstation
OUT_DIR=""
KEY_USES=1
KEY_EXPIRES_HOURS=48

usage() {
  cat <<'EOF'
Sentinel Lite bundle generator

Options:
  --platform <p>    windows | macos | linux | all   (default: all)
  --role <r>        workstation | docker-host | db-host  (default: workstation)
                    Selects which auditd rule file the Linux bundle installs
                    on top of the generic baseline.
  --out <dir>       Output directory
                    (default: /var/lib/vibe-sentinel/lite/<timestamp>)
  --count <n>       How many machines this key may enrol (default: 1).
                    One key per machine is the safe default; raise it only for
                    a supervised rollout batch.
  --expires <h>     Setup-key lifetime in hours (default: 48)
  --help            This text
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)  PLATFORM="${2:?--platform needs a value}"; shift 2 ;;
    --role)      ROLE="${2:?--role needs a value}"; shift 2 ;;
    --out)       OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    --count)     KEY_USES="${2:?--count needs a value}"; shift 2 ;;
    --expires)   KEY_EXPIRES_HOURS="${2:?--expires needs a value}"; shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *) die "Unknown argument: $1" "Run with --help for usage." ;;
  esac
done

case "$PLATFORM" in windows|macos|linux|all) : ;; *) die "Unknown platform '$PLATFORM'." "Valid: windows, macos, linux, all." ;; esac
case "$ROLE" in workstation|docker-host|db-host) : ;; *) die "Unknown role '$ROLE'." "Valid: workstation, docker-host, db-host." ;; esac

require_root
require_cmd jq
[ -f "$SENTINEL_CONFIG" ] || die "No Sentinel installation found at $SENTINEL_CONFIG." \
  "Bundles are generated from a live install — run install.sh first."

DOMAIN="$(config_get '.firm.domain')"
FIRM="$(config_get '.firm.legal_name')"
FIRM_SLUG="$(printf '%s' "$FIRM" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//')"
[ -n "$FIRM_SLUG" ] || FIRM_SLUG="firm"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${OUT_DIR:-/var/lib/vibe-sentinel/lite/$STAMP}"

env_val() { grep -m1 "^$1=" "$SENTINEL_ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }
WAZUH_ENROLLMENT_PW="$(env_val WAZUH_ENROLLMENT_PASSWORD)"
MESH_BIND_IP="$(env_val MESH_BIND_IP)"

[ -n "$WAZUH_ENROLLMENT_PW" ] || die "No WAZUH_ENROLLMENT_PASSWORD in $SENTINEL_ENV_FILE." \
  "The bundle cannot enrol an agent without it. Re-run install.sh to regenerate the environment."

if [ "$MESH_BIND_IP" = "127.0.0.1" ] || [ -z "$MESH_BIND_IP" ]; then
  die "The Sentinel host is not on the mesh yet (MESH_BIND_IP is $MESH_BIND_IP)." \
      "Wazuh agent ports bind to the mesh interface only, so a bundle generated now would point workstations at an unreachable manager. Enrol this host as a NetBird peer, re-run install.sh so the listeners rebind, then generate bundles."
fi

# The manager is reached by NAME over the mesh — NetBird DNS resolves the §2.6
# hostnames to mesh IPs, so a mesh IP change does not invalidate every bundle.
WAZUH_MANAGER_HOST="sentinel.$DOMAIN"
PRINT_HOST="print.$DOMAIN"
VAULT_HOST="vault.$DOMAIN"

# ---------------------------------------------------------------------------
# NetBird one-time setup key, scoped to the workstation group
# ---------------------------------------------------------------------------
NB_SETUP_KEY=""
NB_MGMT_URL="https://nb.$DOMAIN"
mint_setup_key() {
  local token expires body resp
  token="$(cat "$SENTINEL_ETC/secrets/netbird_api_token" 2>/dev/null || true)"
  [ -n "$token" ] || return 1
  expires=$(( KEY_EXPIRES_HOURS * 3600 ))
  body="$(jq -n --arg n "sentinel-lite $FIRM_SLUG $STAMP" \
                --argjson uses "$KEY_USES" --argjson exp "$expires" '{
    name: $n,
    type: (if $uses == 1 then "one-off" else "reusable" end),
    expires_in: $exp,
    usage_limit: $uses,
    auto_groups: ["workstations"],
    ephemeral: false
  }')"
  resp="$(curl -sS --max-time 30 -X POST "$NB_MGMT_URL/api/setup-keys" \
    -H "Authorization: Token $token" -H "Content-Type: application/json" \
    --data "$body" 2>/dev/null || true)"
  NB_SETUP_KEY="$(printf '%s' "$resp" | jq -r '.key // empty' 2>/dev/null)"
  [ -n "$NB_SETUP_KEY" ]
}

if jq -e '.modules.selected | index("mesh")' "$SENTINEL_CONFIG" >/dev/null 2>&1; then
  if ! mint_setup_key; then
    log_warn "Could not mint a NetBird setup key automatically."
    log      "Create one in the NetBird admin UI (https://nb-admin.$DOMAIN): one-off, ${KEY_EXPIRES_HOURS}h, auto-group 'workstations'."
    printf 'Paste the setup key (or press Enter to generate a bundle with a placeholder): '
    read -r NB_SETUP_KEY
  else
    log_ok "NetBird setup key minted (one-off, ${KEY_EXPIRES_HOURS}h, group 'workstations')"
  fi
fi
[ -n "$NB_SETUP_KEY" ] || {
  NB_SETUP_KEY="REPLACE-WITH-SETUP-KEY"
  log_warn "Bundle will carry a PLACEHOLDER setup key — replace it before deployment or enrollment will fail."
}

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
log "Generating Sentinel Lite bundles for $FIRM ($DOMAIN) → $OUT_DIR"

# Shared enrollment facts, consumed by every platform's installer.
ENROLL_JSON="$OUT_DIR/enrollment.json"
( umask 077
  jq -n --arg firm "$FIRM" --arg domain "$DOMAIN" --arg stamp "$STAMP" \
        --arg wazuh_host "$WAZUH_MANAGER_HOST" --arg wazuh_pw "$WAZUH_ENROLLMENT_PW" \
        --arg nb_key "$NB_SETUP_KEY" --arg nb_mgmt "$NB_MGMT_URL" \
        --arg print_host "$PRINT_HOST" --arg vault_host "$VAULT_HOST" \
        --arg role "$ROLE" --argjson uses "$KEY_USES" '{
    firm: $firm,
    domain: $domain,
    generated_at: $stamp,
    role: $role,
    enrollment_order: [
      "netbird",
      "wazuh-agent",
      "sysmon-or-auditd",
      "posture-task",
      "print-queues",
      "print-firewall"
    ],
    netbird: {
      management_url: $nb_mgmt,
      setup_key: $nb_key,
      group: "workstations",
      single_use: ($uses == 1),
      note: "Enrolled FIRST. The Wazuh manager, print queues, and Vaultwarden are all mesh-only; nothing else in this bundle can reach its server until the peer is up."
    },
    wazuh: {
      manager: $wazuh_host,
      port: 1514,
      registration_port: 1515,
      enrollment_password: $wazuh_pw,
      note: "Manager ports bind to the mesh interface only. Reached by NAME so a mesh IP change does not invalidate deployed agents."
    },
    print: { gateway: $print_host, ipp_port: 631, release_ui_port: 8632 },
    vault: { host: $vault_host },
    posture: { interval_hours: 4 },
    privacy: "Sentinel Lite collects security telemetry, not content. No keystrokes, no screenshots, no file contents."
  }' >"$ENROLL_JSON" )
chmod 600 "$ENROLL_JSON"

# ---------------------------------------------------------------------------
# Per-platform staging
# ---------------------------------------------------------------------------
render() { # template-file output-file
  sed -e "s#@@FIRM@@#$(printf '%s' "$FIRM" | sed 's/[&#\\]/\\&/g')#g" \
      -e "s#@@FIRM_SLUG@@#$FIRM_SLUG#g" \
      -e "s#@@DOMAIN@@#$DOMAIN#g" \
      -e "s#@@WAZUH_MANAGER@@#$WAZUH_MANAGER_HOST#g" \
      -e "s#@@WAZUH_ENROLLMENT_PASSWORD@@#$(printf '%s' "$WAZUH_ENROLLMENT_PW" | sed 's/[&#\\]/\\&/g')#g" \
      -e "s#@@NETBIRD_SETUP_KEY@@#$(printf '%s' "$NB_SETUP_KEY" | sed 's/[&#\\]/\\&/g')#g" \
      -e "s#@@NETBIRD_MGMT_URL@@#$NB_MGMT_URL#g" \
      -e "s#@@PRINT_GATEWAY@@#$PRINT_HOST#g" \
      -e "s#@@VAULT_HOST@@#$VAULT_HOST#g" \
      -e "s#@@ROLE@@#$ROLE#g" \
      -e "s#@@STAMP@@#$STAMP#g" \
      "$1" >"$2"
}

stage_common() { # dest-dir
  mkdir -p "$1"
  install -m 600 "$ENROLL_JSON" "$1/enrollment.json"
}

# --- Windows ---------------------------------------------------------------
if [ "$PLATFORM" = "windows" ] || [ "$PLATFORM" = "all" ]; then
  W="$OUT_DIR/windows"
  stage_common "$W"
  mkdir -p "$W/payload"
  install -m 644 "$SCRIPT_DIR/posture/posture.ps1" "$W/payload/posture.ps1"
  if [ -f "$SCRIPT_DIR/print-queue/firewall/block-printer-egress.ps1" ]; then
    render "$SCRIPT_DIR/print-queue/firewall/block-printer-egress.ps1" "$W/payload/block-printer-egress.ps1"
  fi
  if [ -f "$SCRIPT_DIR/print-queue/install-queues.ps1" ]; then
    render "$SCRIPT_DIR/print-queue/install-queues.ps1" "$W/payload/install-queues.ps1"
  fi
  for t in "$SCRIPT_DIR/windows"/*.wxs "$SCRIPT_DIR/windows"/*.ps1 "$SCRIPT_DIR/windows"/*.md; do
    [ -f "$t" ] || continue
    render "$t" "$W/$(basename "$t")"
  done
  chmod -R go-rwx "$W"
  log_ok "Windows bundle staged: $W"
  log    "  Build the MSI on a Windows box with the WiX Toolset:  candle sentinel-lite.wxs && light sentinel-lite.wixobj"
  log    "  The MSI needs the Wazuh agent MSI, Sysmon, and the NetBird MSI dropped into payload/ first — see windows/README.md."
fi

# --- macOS -----------------------------------------------------------------
if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "all" ]; then
  M="$OUT_DIR/macos"
  stage_common "$M"
  mkdir -p "$M/payload"
  install -m 755 "$SCRIPT_DIR/posture/posture.sh" "$M/payload/posture.sh"
  for t in "$SCRIPT_DIR/macos"/*; do
    [ -f "$t" ] || continue
    render "$t" "$M/$(basename "$t")"
    case "$(basename "$t")" in *.sh) chmod 755 "$M/$(basename "$t")" ;; esac
  done
  chmod -R go-rwx "$M"
  log_ok "macOS bundle staged: $M"
  log    "  Build on a Mac:  bash build-pkg.sh   (notarization is a documented TODO — see the header)"
fi

# --- Linux -----------------------------------------------------------------
if [ "$PLATFORM" = "linux" ] || [ "$PLATFORM" = "all" ]; then
  L="$OUT_DIR/linux"
  stage_common "$L"
  mkdir -p "$L/payload/auditd"
  install -m 755 "$SCRIPT_DIR/posture/posture.sh" "$L/payload/posture.sh"

  # auditd: the generic baseline on EVERY host, plus the per-role file.
  if [ -f "$AUDITD_RULES_DIR/generic.rules" ]; then
    install -m 640 "$AUDITD_RULES_DIR/generic.rules" "$L/payload/auditd/50-sentinel-generic.rules"
    log_ok "  auditd baseline: 50-sentinel-generic.rules"
  else
    log_warn "  auditd generic.rules not found at $AUDITD_RULES_DIR — set MONOREPO_ROOT to the Vibe-Sentinel checkout."
    log      "  Without it the Linux bundle installs no audit rules and the host-integrity pack (SENT-H-*) will be silent."
  fi
  if [ "$ROLE" != "workstation" ]; then
    if [ -f "$AUDITD_RULES_DIR/$ROLE.rules" ]; then
      install -m 640 "$AUDITD_RULES_DIR/$ROLE.rules" "$L/payload/auditd/60-sentinel-$ROLE.rules"
      log_ok "  auditd role overlay: 60-sentinel-$ROLE.rules"
    else
      log_warn "  No auditd rule file for role '$ROLE' at $AUDITD_RULES_DIR/$ROLE.rules — the bundle ships the generic baseline only."
    fi
  fi

  for t in "$SCRIPT_DIR/linux"/*; do
    [ -f "$t" ] || continue
    render "$t" "$L/$(basename "$t")"
    case "$(basename "$t")" in *.sh) chmod 755 "$L/$(basename "$t")" ;; esac
  done
  chmod -R go-rwx "$L"
  log_ok "Linux bundle staged: $L"
  log    "  Build the .deb:  bash build-deb.sh"
fi

# ---------------------------------------------------------------------------
# Bundle manifest and closing guidance
# ---------------------------------------------------------------------------
( umask 077
  jq -n --arg firm "$FIRM" --arg domain "$DOMAIN" --arg stamp "$STAMP" \
        --arg platform "$PLATFORM" --arg role "$ROLE" \
        --argjson uses "$KEY_USES" --argjson expires "$KEY_EXPIRES_HOURS" '{
    bundle: "sentinel-lite",
    firm: $firm, domain: $domain, role: $role,
    generated_at: $stamp,
    platforms: (if $platform == "all" then ["windows","macos","linux"] else [$platform] end),
    setup_key: { uses: $uses, expires_hours: $expires },
    handling: "CONTAINS CREDENTIALS: a NetBird setup key and the Wazuh enrollment password. Treat this directory like a password. Transfer it over the mesh or on encrypted media, never by email."
  }' >"$OUT_DIR/BUNDLE.json" )
chmod 600 "$OUT_DIR/BUNDLE.json"

hr 2>/dev/null || true
log_ok "Bundles generated in $OUT_DIR"
cat <<EOF

Before you deploy:

  1. This directory holds a NetBird setup key and the Wazuh enrollment
     password. Treat it like a password: move it over the mesh or on encrypted
     media, never by email, and delete it when the batch is enrolled.
  2. The setup key allows ${KEY_USES} enrollment(s) and expires in ${KEY_EXPIRES_HOURS}h.
     Generate a fresh bundle per batch rather than reusing one.
  3. Enrollment order is NOT negotiable: NetBird first, everything else after.
     Each installer enforces it; do not "fix" a slow install by reordering.
  4. Tell staff what this collects before it lands on their machine. The
     privacy stance is in enrollment.json and belongs in the WISP: security
     telemetry, not content — no keystrokes, no screenshots, no file contents.

EOF
