#!/usr/bin/env bash
# lib/secrets.sh — .env (600) writer, Docker secrets, and image-ref resolution
# from versions/manifest.json. All secrets live either in Docker secrets or in
# the 600-permission .env, which is FIM-monitored once Wazuh is up (plan §2.2).
# shellcheck shell=bash

SECRETS_DIR="${SECRETS_DIR:-$SENTINEL_ETC/secrets}"

# ---------------------------------------------------------------------------
# Image resolution: prefer digest pin; fall back to tag while digest is the
# Phase 0 placeholder ("sha256:TODO-pin-during-phase0").
# ---------------------------------------------------------------------------
resolve_image() { # manifest-key -> echoes full image ref
  local repo tag digest
  repo="$(json_get "$MANIFEST_FILE" ".images[\"$1\"].repo")"
  tag="$(json_get "$MANIFEST_FILE" ".images[\"$1\"].tag")"
  digest="$(json_get "$MANIFEST_FILE" ".images[\"$1\"].digest")"
  [ -n "$repo" ] || die "Image '$1' missing from versions/manifest.json" \
    "The manifest must list every image the selected modules reference."
  if [ -n "$digest" ] && [ "${digest#sha256:TODO}" = "$digest" ]; then
    printf '%s@%s' "$repo" "$digest"
  else
    printf '%s:%s' "$repo" "$tag"
  fi
}

# Emit IMG_<KEY>=ref lines for every image in the manifest (keys upper-cased,
# hyphens → underscores) so module compose files can use ${IMG_...} everywhere.
emit_image_env() {
  local key
  for key in $(jq -r '.images | keys[]' "$MANIFEST_FILE"); do
    printf 'IMG_%s=%s\n' \
      "$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')" \
      "$(resolve_image "$key")"
  done
}

# ---------------------------------------------------------------------------
# Secret material — generated once, then reused on re-runs (idempotent).
# ---------------------------------------------------------------------------
ensure_secret_file() { # name generator-command...
  local f="$SECRETS_DIR/$1"; shift
  mkdir -p "$SECRETS_DIR"; chmod 700 "$SECRETS_DIR"
  if [ ! -s "$f" ]; then
    ( umask 077; "$@" >"$f" )
  fi
  chmod 600 "$f"
  printf '%s' "$f"
}

secret_value() { cat "$SECRETS_DIR/$1"; }

generate_core_secrets() {
  ensure_secret_file pg_password             openssl rand -hex 24 >/dev/null
  ensure_secret_file authentik_secret_key    openssl rand -hex 32 >/dev/null
  ensure_secret_file authentik_bootstrap_pw  openssl rand -base64 18 >/dev/null
  ensure_secret_file authentik_bootstrap_token openssl rand -hex 32 >/dev/null
  ensure_secret_file wazuh_api_password      openssl rand -base64 18 >/dev/null
  ensure_secret_file wazuh_enrollment_pw     openssl rand -hex 16 >/dev/null
  ensure_secret_file restic_password         openssl rand -hex 24 >/dev/null
  ensure_secret_file sentinel_api_secret     openssl rand -hex 32 >/dev/null
  # Vibe Print's ONLY credential: one shared bearer secret gating /admin and
  # every /v1 call. There is no user model behind it and the gateway refuses
  # to boot when it is empty. Generated once and reused on every re-run -
  # rotating it cuts off every caller and every signed-in admin at once.
  ensure_secret_file vibe_print_secret       openssl rand -hex 32 >/dev/null
  # Cloudflare token arrives from the wizard; store it as a file-backed secret.
  local cf_token
  cf_token="$(config_get '.cloudflare.api_token')"
  if [ -n "$cf_token" ]; then
    ( umask 077; printf '%s' "$cf_token" >"$SECRETS_DIR/cf_api_token" )
    chmod 600 "$SECRETS_DIR/cf_api_token"
  fi
  local smtp_pass
  smtp_pass="$(config_get '.smtp.password')"
  if [ -n "$smtp_pass" ]; then
    ( umask 077; printf '%s' "$smtp_pass" >"$SECRETS_DIR/smtp_password" )
  fi
  # The keys module declares smtp_password as a file-backed secret, so Compose
  # refuses to start when the file is missing. A relay that needs no password is
  # a legitimate configuration, so create it empty rather than failing the stack.
  [ -f "$SECRETS_DIR/smtp_password" ] || ( umask 077; : >"$SECRETS_DIR/smtp_password" )
  chmod 600 "$SECRETS_DIR/smtp_password"

  # Greenbone (scan module, off by default) generates its own credentials so the
  # operator never has to paste them; harmless when the module is not selected.
  ensure_secret_file greenbone_db_password    openssl rand -hex 24 >/dev/null
  ensure_secret_file greenbone_admin_password openssl rand -base64 18 >/dev/null
}

# ---------------------------------------------------------------------------
# .env writer — one merged env for the generated compose. 600 perms, root-owned.
# ---------------------------------------------------------------------------
write_env_file() {
  mkdir -p "$SENTINEL_ETC"
  local domain mesh_bind smtp_host smtp_port smtp_user smtp_from vw_mode vw_domain
  domain="$(config_get '.firm.domain')"
  mesh_bind="$(config_get '.network.mesh_bind_ip' '127.0.0.1')"
  smtp_host="$(config_get '.smtp.host')"
  smtp_port="$(config_get '.smtp.port' '587')"
  smtp_user="$(config_get '.smtp.username')"
  smtp_from="$(config_get '.smtp.from' "sentinel@${domain}")"
  vw_mode="$(config_get '.modules.keys.vaultwarden_mode' 'tunnel')"
  # DOMAIN follows the published mode (plan §2.2): both modes use vault.<domain>;
  # what differs is how the hostname is published (tunnel vs mesh-only DNS).
  vw_domain="https://vault.${domain}"

  {
    echo "# Generated by vibe-sentinel-installer $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# chmod 600 — FIM-monitored (SENT-H-001). Do not hand-edit; re-run the wizard."
    echo "SENTINEL_MODULES_DIR=$SENTINEL_ETC/modules"
    echo "SENTINEL_DATA_DIR=/var/lib/vibe-sentinel"
    echo "SENTINEL_DOMAIN=$domain"
    echo "MESH_BIND_IP=$mesh_bind"
    echo "TZ=$(config_get '.firm.timezone' 'America/Chicago')"
    echo ""
    echo "# --- Postgres (single instance; databases sentinel/authentik/vaultwarden) ---"
    echo "POSTGRES_USER=sentinel"
    echo "POSTGRES_PASSWORD=$(secret_value pg_password)"
    echo ""
    echo "# --- Authentik (core; serves Sentinel UI + NetBird only — Decision 21) ---"
    echo "AUTHENTIK_SECRET_KEY=$(secret_value authentik_secret_key)"
    echo "AUTHENTIK_BOOTSTRAP_PASSWORD=$(secret_value authentik_bootstrap_pw)"
    echo "AUTHENTIK_BOOTSTRAP_TOKEN=$(secret_value authentik_bootstrap_token)"
    echo "AUTHENTIK_BOOTSTRAP_EMAIL=$(config_get '.firm.qi_email')"
    echo ""
    echo "# --- SMTP relay (wizard-collected; preflight-verified) ---"
    echo "SMTP_HOST=$smtp_host"
    echo "SMTP_PORT=$smtp_port"
    echo "SMTP_USERNAME=$smtp_user"
    echo "SMTP_FROM=$smtp_from"
    echo ""
    echo "# --- Wazuh ---"
    echo "WAZUH_API_PASSWORD=$(secret_value wazuh_api_password)"
    echo "WAZUH_ENROLLMENT_PASSWORD=$(secret_value wazuh_enrollment_pw)"
    echo ""
    echo "# --- Sentinel app ---"
    echo "SENTINEL_API_SECRET=$(secret_value sentinel_api_secret)"
    echo "SENTINEL_AI_MODE=$(config_get '.modules.ai.mode' 'local')"
    echo ""
    echo "# --- Vaultwarden (keys module) ---"
    echo "VAULTWARDEN_MODE=$vw_mode"
    echo "VAULTWARDEN_DOMAIN=$vw_domain"
    echo "EVENTS_DAYS_RETAIN=$(config_get '.modules.keys.events_days_retain' '1095')"
    echo ""
    echo "# --- Backups (core built-in restic, profile no-vault) ---"
    echo "RESTIC_PASSWORD=$(secret_value restic_password)"
    echo "RESTIC_REPOSITORY=$(config_get '.backup.restic_repository' '/var/lib/vibe-sentinel/restic-repo')"
    echo "BACKUP_WINDOW=$(config_get '.firm.backup_window' '01:00-03:00')"
    echo ""
    echo "# --- Print module (ghcr.io/kisaesdevlab/vibe-printer) ---"
    echo "VIBE_PRINT_SECRET=$(secret_value vibe_print_secret)"
    echo "PRINT_JOB_RETENTION_DAYS=$(config_get '.modules.print.job_retention_days' '30')"
    echo "PRINT_AUDIT_RETENTION_DAYS=$(config_get '.modules.print.audit_retention_days' '365')"
    # Labels each print job as on-premises or not in the audit log, and scopes
    # printer-network-policy.sh. It does not gate anything: every job prints on
    # submission (held/PIN release withdrawn, build plan v1.7 §11 R26).
    echo "ONSITE_SUBNETS=$(config_get '.firm.onsite_subnets_csv')"
    echo ""
    echo "# --- Scan module (Greenbone; off by default, loopback only) ---"
    echo "GREENBONE_DB_PASSWORD=$(secret_value greenbone_db_password)"
    echo "GREENBONE_ADMIN_PASSWORD=$(secret_value greenbone_admin_password)"
    echo "GREENBONE_SCAN_TARGETS=$(config_get '.modules.scan.targets_csv')"
    echo "GREENBONE_SCAN_SCHEDULE=$(config_get '.modules.scan.schedule')"
    echo ""
    echo "# --- Falco (preflight kernel/BTF result) ---"
    echo "FALCO_PRIVILEGED_FALLBACK=$(config_get '.preflight.falco_privileged_fallback' 'false')"
    echo ""
    echo "# --- Image pins from versions/manifest.json (digest-pinned once Phase 0 pins land) ---"
    emit_image_env
  } >"$SENTINEL_ENV_FILE.tmp"
  mv "$SENTINEL_ENV_FILE.tmp" "$SENTINEL_ENV_FILE"
  chown root:root "$SENTINEL_ENV_FILE"
  chmod 600 "$SENTINEL_ENV_FILE"
  log_ok ".env written to $SENTINEL_ENV_FILE (mode 600)"
}

# ---------------------------------------------------------------------------
# Docker secrets. Compose (non-swarm) consumes file-backed secrets; the
# generated compose maps these under the top-level `secrets:` key.
# ---------------------------------------------------------------------------
write_docker_secrets() {
  generate_core_secrets
  log_ok "Docker secrets materialized under $SECRETS_DIR (mode 600, dir 700)"
}
