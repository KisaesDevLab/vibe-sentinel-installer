#!/usr/bin/env bash
# modules/mesh/setup-cloudflare.sh — the §2.2 NetBird bootstrap path.
#
# Two things must be true or the mesh will not work, and both are installer
# responsibilities (plan §2.2):
#   1. Zone gRPC proxying enabled AND tunnel ingress for nb./nb-signal. sets
#      http2Origin: true            → done by lib/cloudflare.sh at install
#      (re-verified here).
#   2. Cloudflare Access BYPASS policies on the machine-facing endpoints —
#      peers and clients must reach them BEFORE they are on the mesh, and
#      NetBird clients cannot complete an interactive Access login:
#        nb.<domain>            (management gRPC/API)
#        nb-signal.<domain>     (signal gRPC)
#        id.<domain>/application/o/*     (Authentik OIDC)
#        id.<domain>/.well-known/*       (OIDC discovery)
#      Dashboards (nb-admin., wazuh., sentinel., Authentik admin UI) STAY
#      behind Access. CrowdSec + Cloudflare WAF rate-limit the bypassed
#      endpoints; the bypass list itself is watched by SENT-V-SENT-001.
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
cf_discover_zone "$DOMAIN"

# 1. Re-verify gRPC + ingress (idempotent; created at install)
cf_enable_grpc

# 2. Access BYPASS policies for machine-facing endpoints only
cf_bypass_machine_endpoint "NetBird Management (machine)" "nb.$DOMAIN"
cf_bypass_machine_endpoint "NetBird Signal (machine)"     "nb-signal.$DOMAIN"
cf_bypass_machine_endpoint "Authentik OIDC (machine)"     "id.$DOMAIN/application/o/*"
cf_bypass_machine_endpoint "Authentik OIDC discovery"     "id.$DOMAIN/.well-known/*"

# Dashboards remain behind Access (created at install by install.sh):
#   sentinel.$DOMAIN, wazuh.$DOMAIN, nb-admin.$DOMAIN, id.$DOMAIN/if/admin/*
log_ok "Mesh bootstrap path configured: gRPC on, http2Origin ingress, Access bypass on machine endpoints only."
log    "The bypass list is monitored — any change raises SENT-V-SENT-001."

# 3. Render management.json domain placeholders (idempotent).
MGMT_JSON="$SENTINEL_ETC/modules/mesh/management.json"
if grep -q '__SENTINEL_DOMAIN__' "$MGMT_JSON" 2>/dev/null; then
  sed -i "s/__SENTINEL_DOMAIN__/$DOMAIN/g" "$MGMT_JSON"
  log_ok "management.json rendered for $DOMAIN (restart netbird-management to pick it up)"
fi
