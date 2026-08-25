#!/usr/bin/env bash
# install.sh — Vibe Sentinel standalone appliance installer (plan §2.5/§2.6).
#
#   curl -fsSL https://get.vibesentinel.app/install.sh | bash
#   # or, from a checkout:
#   sudo bash install.sh [--modules core,runtime,edge,...] [--unattended --config firm.json]
#
# Flow: parse args → require root → host preflight → wizard (or config file)
# → credential preflight (Cloudflare scopes, SMTP, DNS) → secrets + .env(600)
# → merged compose → Cloudflare provisioning → §2.6 first-boot ordering with
# a health gate on every step. A failed gate halts with the step name and
# remediation text; the installer never leaves a half-built stack silently.

set -euo pipefail

ORIG_ARGS="$*"
REPO_URL="${SENTINEL_REPO_URL:-https://github.com/KisaesDevLab/vibe-sentinel-installer.git}"

# --- curl|bash bootstrap: fetch the full repo if we are running bare ---------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /)"
if [ ! -f "$SCRIPT_DIR/lib/common.sh" ]; then
  echo "[sentinel] Bootstrap: fetching installer repo to /opt/vibe-sentinel-installer"
  command -v git >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq git; }
  if [ -d /opt/vibe-sentinel-installer/.git ]; then
    git -C /opt/vibe-sentinel-installer pull --ff-only
  else
    git clone --depth 1 "$REPO_URL" /opt/vibe-sentinel-installer
  fi
  exec bash /opt/vibe-sentinel-installer/install.sh "$@"
fi

INSTALLER_ROOT="$SCRIPT_DIR"
# shellcheck source=lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"
# shellcheck source=lib/health.sh
. "$INSTALLER_ROOT/lib/health.sh"
# shellcheck source=lib/secrets.sh
. "$INSTALLER_ROOT/lib/secrets.sh"
# shellcheck source=lib/compose-merge.sh
. "$INSTALLER_ROOT/lib/compose-merge.sh"
# shellcheck source=lib/cloudflare.sh
. "$INSTALLER_ROOT/lib/cloudflare.sh"
# shellcheck source=wizard/wizard.sh
. "$INSTALLER_ROOT/wizard/wizard.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
UNATTENDED=0
CONFIG_FILE=""
CLI_MODULES=""

usage() {
  cat <<'EOF'
Vibe Sentinel installer

Options:
  --modules <list>    Comma-separated module list (core is always included).
                      Modules: core runtime edge mesh keys pulse print scan ai
  --unattended        No prompts; requires --config.
  --config <file>     Pre-answered firm config JSON (same shape the wizard writes).
  --help              This text.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --modules)    CLI_MODULES="${2:?--modules needs a value}"; shift 2 ;;
    --modules=*)  CLI_MODULES="${1#*=}"; shift ;;
    --unattended) UNATTENDED=1; shift ;;
    --config)     CONFIG_FILE="${2:?--config needs a value}"; shift 2 ;;
    --config=*)   CONFIG_FILE="${1#*=}"; shift ;;
    --help|-h)    usage; exit 0 ;;
    *) die "Unknown argument: $1" "Run with --help for usage." ;;
  esac
done

require_root
mkdir -p "$SENTINEL_ETC"

# ---------------------------------------------------------------------------
# Preflight — phase A (host facts; no firm inputs needed)
# ---------------------------------------------------------------------------
run_preflight() { # script-basename function-name
  # shellcheck disable=SC1090
  . "$INSTALLER_ROOT/preflight/$1"
  "$2"
}

log "Preflight (host) — every check prints PASS or FAIL with a plain-English reason."
PREFLIGHT_A_FAILED=0
run_preflight os.sh        preflight_os        || PREFLIGHT_A_FAILED=1
run_preflight docker.sh    preflight_docker    || PREFLIGHT_A_FAILED=1
run_preflight kernel.sh    preflight_kernel    || PREFLIGHT_A_FAILED=1
run_preflight sysctl.sh    preflight_sysctl    || PREFLIGHT_A_FAILED=1
run_preflight auditd.sh    preflight_auditd    || PREFLIGHT_A_FAILED=1
run_preflight timesync.sh  preflight_timesync  || PREFLIGHT_A_FAILED=1
[ "$PREFLIGHT_A_FAILED" -eq 0 ] || \
  die "Host preflight failed — see the FAIL lines above." \
      "Fix each FAIL reason, then re-run. Nothing has been installed or changed beyond sysctl/auditd/timesync enablement."

# ---------------------------------------------------------------------------
# Wizard or config file
# ---------------------------------------------------------------------------
if [ -n "$CONFIG_FILE" ]; then
  [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE" "Pass a JSON file with the shape the wizard writes (see README)."
  jq -e . "$CONFIG_FILE" >/dev/null || die "Config file is not valid JSON: $CONFIG_FILE"
  install -m 600 "$CONFIG_FILE" "$SENTINEL_CONFIG"
  log_ok "Using supplied config: $CONFIG_FILE → $SENTINEL_CONFIG"
  SELECTED_MODULES="$(jq -r '.modules.selected | join(" ")' "$SENTINEL_CONFIG")"
elif [ "$UNATTENDED" -eq 1 ]; then
  die "--unattended requires --config <file>." "Run once interactively to produce /etc/vibe-sentinel/config.json, then reuse it."
else
  run_wizard
fi

# CLI --modules overrides the config's module list (compensating-control
# entries from the wizard/config are preserved).
if [ -n "$CLI_MODULES" ]; then
  SELECTED_MODULES="$(validate_module_list "$CLI_MODULES")"
  tmp="$(mktemp)"
  jq --arg m "$SELECTED_MODULES" '.modules.selected = ($m | split(" "))' "$SENTINEL_CONFIG" >"$tmp" && mv "$tmp" "$SENTINEL_CONFIG"
  chmod 600 "$SENTINEL_CONFIG"
fi
SELECTED_MODULES="$(validate_module_list "${SELECTED_MODULES:-$DEFAULT_MODULES}")"
export SELECTED_MODULES
log "Selected modules: $SELECTED_MODULES"

# Guard: disabling a Security Six module without a recorded compensating
# control is refused (plan §2.5) — matters for --config / --modules paths.
for m in $SECURITY_SIX_MODULES; do
  if ! module_selected "$m"; then
    cc="$(config_get ".modules.compensating_controls[\"$m\"]")"
    [ -n "$cc" ] || die "Module '$m' is disabled but no compensating control is recorded." \
      "Security Six controls need an answer. Add .modules.compensating_controls.$m (e.g. \"firm uses Tailscale\") to the config, or enable the module."
  fi
done

# Persist the kernel preflight's Falco verdict into the config.
tmp="$(mktemp)"
jq --arg v "${FALCO_PRIVILEGED_FALLBACK:-false}" '.preflight.falco_privileged_fallback = $v' \
  "$SENTINEL_CONFIG" >"$tmp" && mv "$tmp" "$SENTINEL_CONFIG"
chmod 600 "$SENTINEL_CONFIG"

# ---------------------------------------------------------------------------
# Preflight — phase B (needs wizard answers: resources, ports, DNS, CF, SMTP)
# ---------------------------------------------------------------------------
log "Preflight (firm inputs)"
PREFLIGHT_B_FAILED=0
run_preflight resources.sh  preflight_resources  || PREFLIGHT_B_FAILED=1
run_preflight ports.sh      preflight_ports      || PREFLIGHT_B_FAILED=1
run_preflight dns.sh        preflight_dns        || PREFLIGHT_B_FAILED=1
run_preflight cloudflare.sh preflight_cloudflare || PREFLIGHT_B_FAILED=1
run_preflight smtp.sh       preflight_smtp       || PREFLIGHT_B_FAILED=1
[ "$PREFLIGHT_B_FAILED" -eq 0 ] || \
  die "Preflight failed on the firm-supplied inputs — see the FAIL lines above." \
      "Fix the token scopes / SMTP / DNS issue named above and re-run. Your wizard answers are saved in $SENTINEL_CONFIG."

# ---------------------------------------------------------------------------
# Generate: secrets, .env (600), staged modules, merged compose
# ---------------------------------------------------------------------------
write_docker_secrets
write_env_file
stage_modules
validate_env_schema
merge_compose

# ---------------------------------------------------------------------------
# Cloudflare provisioning: tunnel, ingress (http2Origin for NetBird gRPC),
# gRPC zone setting, DNS records per §2.6, Access apps + bypass policies.
# ---------------------------------------------------------------------------
DOMAIN="$(config_get '.firm.domain')"
VW_MODE="$(config_get '.modules.keys.vaultwarden_mode' 'tunnel')"
cf_discover_zone "$DOMAIN"
TUNNEL_ID="$(cf_ensure_tunnel "vibe-sentinel-$(printf '%s' "$DOMAIN" | tr '.' '-')")"
cf_configure_tunnel_ingress "$TUNNEL_ID" "$VW_MODE"
cf_enable_grpc
# Mesh IP is unknown until NetBird is up — mesh-only records start at the
# loopback placeholder and are corrected after the mesh step below.
cf_provision_hostnames "$TUNNEL_ID" "$(config_get '.network.mesh_bind_ip' '127.0.0.1')" "$VW_MODE"

# Dashboards behind Access; machine-facing endpoints bypassed (§2.2).
EMAIL_DOMAIN="${DOMAIN}"
cf_protect_dashboard "Sentinel Dashboard"  "sentinel.$DOMAIN" "$EMAIL_DOMAIN"
cf_protect_dashboard "Wazuh Dashboard"     "wazuh.$DOMAIN"    "$EMAIL_DOMAIN"
cf_protect_dashboard "NetBird Admin"       "nb-admin.$DOMAIN" "$EMAIL_DOMAIN"
cf_protect_dashboard "Authentik Admin"     "id.$DOMAIN/if/admin/*" "$EMAIL_DOMAIN"

# ---------------------------------------------------------------------------
# First-boot ordering (§2.6) — every step gated on health, halt on failure:
# Postgres/Redis → Authentik → certs wildcard → Sentinel API/web → Wazuh
# indexer → manager → dashboard → ntfy → CrowdSec → Falco → mesh → keys →
# pulse → print → scan.
# ---------------------------------------------------------------------------
up() { compose_cmd up -d --no-deps "$@"; }

log "First boot — §2.6 ordering with a health gate on every step."

# 1. Postgres + Redis
up sentinel-db sentinel-redis
wait_healthy "Postgres (sentinel-db)" 180 \
  "Postgres failed to become ready. Check volume permissions under /var/lib/vibe-sentinel and the db-init logs." \
  check_pg_ready sentinel-db sentinel
wait_healthy "Redis (sentinel-redis)" 60 \
  "Redis failed to start — check container logs." \
  check_redis_ready sentinel-redis

# 2. Authentik (bootstrap tenant, QI admin, groups, OIDC apps)
up authentik-server authentik-worker
wait_healthy "Authentik (id.$DOMAIN)" 420 \
  "Authentik did not come healthy. Verify AUTHENTIK_SECRET_KEY in $SENTINEL_ENV_FILE and that the authentik database was created (docker compose logs sentinel-db)." \
  check_http_ok "http://127.0.0.1:9000/-/health/ready/" insecure

# 3. Certs sidecar — ACME DNS-01 wildcard must exist before mesh-only TLS services
up sentinel-certs
wait_healthy "Wildcard certificate (*.${DOMAIN} via ACME DNS-01)" 600 \
  "The lego sidecar could not obtain the wildcard certificate. Check the Cloudflare token's Zone DNS:Edit scope and outbound 443 to Let's Encrypt; logs: docker compose logs sentinel-certs" \
  check_file_exists "/var/lib/vibe-sentinel/certs/live/wildcard.crt"

# 4. Sentinel API / web / worker
up sentinel-api sentinel-worker sentinel-web
wait_healthy "Sentinel API" 300 \
  "sentinel-api failed its /healthz. Check DB migration logs: docker compose logs sentinel-api" \
  check_http_ok "http://127.0.0.1:8081/healthz"

# 4a. Break-glass Owner (plan §2.3). This is the only credential that does not
# depend on Authentik, which is the whole point of it — so it is displayed once,
# here, and never again. Only an argon2 hash and an encrypted TOTP secret are
# stored; a re-run rotates rather than reveals. Any use raises SENT-V-SENT-001.
#
# INVARIANT: the credential goes to the terminal and nowhere else. Only explicit
# log_* calls reach $SENTINEL_LOG, and none of them carry it. Do not wrap this
# installer in `tee`, `script`, or a redirect to a file without excluding this
# block — doing so writes the recovery credential to disk in the clear.
provision_break_glass() {
  local qi_email
  qi_email="$(config_get '.firm.qi_email')"
  [ -n "$qi_email" ] || die "No QI email on the firm record — re-run the wizard before provisioning break-glass."
  compose_cmd exec -T sentinel-api node --experimental-strip-types \
    apps/api/src/ops/provision-break-glass.ts --email "$qi_email"
}
if provision_break_glass; then
  # Pause so the credential is not scrolled off by the remaining install output.
  if [ "${UNATTENDED:-false}" != "true" ] && [ -t 0 ]; then
    printf '\nWrite the credential above down now — it cannot be shown again.\nPress Enter to continue the install: '
    read -r _
  else
    warn "Unattended install: the break-glass credential is above in this transcript. Capture it and clear the transcript."
  fi
else
  die "Break-glass provisioning failed. The stack is up but has no recovery account; fix this before handing the system over: pnpm break-glass --email <qi-email>"
fi

# 5-7. Wazuh: indexer → manager → dashboard
up wazuh-indexer
wait_healthy "Wazuh indexer (OpenSearch)" 600 \
  "OpenSearch did not go green. Verify vm.max_map_count=262144 (preflight set it) and free RAM; logs: docker compose logs wazuh-indexer" \
  check_http_ok "https://127.0.0.1:9200/_cluster/health" insecure
up wazuh-manager
wait_healthy "Wazuh manager" 420 \
  "The Wazuh manager did not become healthy — check docker compose logs wazuh-manager" \
  check_container_healthy wazuh-manager
up wazuh-dashboard
wait_healthy "Wazuh dashboard" 420 \
  "The Wazuh dashboard did not come up — it needs the indexer green first; logs: docker compose logs wazuh-dashboard" \
  check_container_healthy wazuh-dashboard

# 8. ntfy
up ntfy
wait_healthy "ntfy push notifications" 120 \
  "ntfy failed to start — docker compose logs ntfy" \
  check_container_healthy ntfy

# 9. CrowdSec (edge)
if module_selected edge; then
  up crowdsec cs-firewall-bouncer
  wait_healthy "CrowdSec LAPI" 180 \
    "CrowdSec LAPI not answering on loopback :8080 — docker compose logs crowdsec" \
    check_http_ok "http://127.0.0.1:8080/health"
  bash "$SENTINEL_ETC/modules/edge/cloudflare-worker-bouncer.sh" || \
    log_warn "Cloudflare Worker bouncer deployment reported an issue — see modules/edge/NOTES.md; CrowdSec local blocking is active regardless."
fi

# 10. Falco (runtime)
if module_selected runtime; then
  up falco falcosidekick
  wait_healthy "Falco runtime detection" 240 \
    "Falco failed to load its eBPF probe. If the kernel lacks BTF the installer already fell back to privileged mode; check docker compose logs falco" \
    check_container_healthy falco
fi

# 11. Mesh (NetBird + Access bypass policies + DNS)
if module_selected mesh; then
  up netbird-management netbird-signal netbird-dashboard
  wait_healthy "NetBird management/signal" 300 \
    "NetBird management or signal failed to start — docker compose logs netbird-management netbird-signal" \
    check_all_healthy netbird-management netbird-signal
  bash "$SENTINEL_ETC/modules/mesh/setup-cloudflare.sh"
  # Rebind mesh-only listeners to the real mesh IP now that the mesh exists.
  MESH_IP="$(ip -4 addr show wt0 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
  if [ -n "${MESH_IP:-}" ]; then
    tmp="$(mktemp)"; jq --arg ip "$MESH_IP" '.network.mesh_bind_ip = $ip' "$SENTINEL_CONFIG" >"$tmp" && mv "$tmp" "$SENTINEL_CONFIG"; chmod 600 "$SENTINEL_CONFIG"
    sed -i "s/^MESH_BIND_IP=.*/MESH_BIND_IP=$MESH_IP/" "$SENTINEL_ENV_FILE"
    merge_compose
    compose_cmd up -d
    cf_provision_hostnames "$TUNNEL_ID" "$MESH_IP" "$VW_MODE"
    log_ok "Mesh-bound services rebound to mesh IP $MESH_IP"
  else
    log_warn "No NetBird interface (wt0) on this host yet — mesh-bound services stay on 127.0.0.1 until the Sentinel host peer enrolls. Re-run the installer after enrolling to rebind."
  fi
fi

# 12. Keys (Vaultwarden)
if module_selected keys; then
  up vaultwarden
  wait_healthy "Vaultwarden" 240 \
    "Vaultwarden failed to start. Check DATABASE_URL and that the vaultwarden database exists; docker compose logs vaultwarden" \
    check_container_healthy vaultwarden
  if [ "$VW_MODE" = "tunnel" ]; then
    bash "$SENTINEL_ETC/modules/keys/tunnel-mode-setup.sh"
  fi
fi

# 13. Pulse (Uptime Kuma)
if module_selected pulse; then
  up uptime-kuma
  wait_healthy "Uptime Kuma" 240 \
    "Uptime Kuma failed to start — docker compose logs uptime-kuma" \
    check_container_healthy uptime-kuma
fi

# 14. Print (Vibe Print)
if module_selected print; then
  up vibe-print vibe-print-release vibe-print-scanner-inbox
  wait_healthy "Vibe Print gateway" 300 \
    "The Vibe Print gateway (CUPS) failed to start — docker compose logs vibe-print" \
    check_container_healthy vibe-print
fi

# 15. Scan (Greenbone)
if module_selected scan; then
  up gb-pg gb-redis gb-mqtt gvmd ospd-openvas gsa
  wait_healthy "Greenbone (gvmd + web UI)" 900 \
    "Greenbone takes a while on first boot (feed sync). If it never comes healthy: docker compose logs gvmd gsa" \
    check_container_healthy gsa
fi

# Backup: firms without Vibe Vault get the built-in restic job (§2.4).
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'vibe-vault'; then
  log "No Vibe Vault detected on this host — enabling the built-in restic backup job (profile no-vault)."
  compose_cmd --profile no-vault up -d sentinel-backup
fi

# AI module: config only, no container.
if module_selected ai; then
  bash "$SENTINEL_ETC/modules/ai/setup.sh"
fi

hr 2>/dev/null || true
log_ok "Vibe Sentinel is up. Dashboard: https://sentinel.$DOMAIN (behind Cloudflare Access)"
log    "Authentik first login: $(config_get '.firm.qi_email') / password in $SECRETS_DIR/authentik_bootstrap_pw"
log    "Next: generate endpoint bundles with lite/generate-lite.sh and enroll workstations."
