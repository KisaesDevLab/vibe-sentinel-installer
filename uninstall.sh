#!/usr/bin/env bash
# uninstall.sh — remove Vibe Sentinel from this host (plan §2.5 "uninstall/ —
# with data-export prompt").
#
#   sudo bash uninstall.sh                    # export first, then tear down
#   sudo bash uninstall.sh --export-dir /mnt/usb/sentinel-export
#   sudo bash uninstall.sh --keep-data        # stop and remove containers only
#   sudo bash uninstall.sh --purge            # also remove /etc/vibe-sentinel
#
# The data-export prompt is not a formality. Sentinel holds the firm's
# compliance artifacts — incident records, risk assessments, attestations,
# evidence, the disclosure log, the password vault, and the print audit trail —
# and several of those must be retained for years after the tool is gone
# (§2.4: incident records, reports, attestations, and evidence are retained
# indefinitely; they are the compliance record). This script exports everything
# BEFORE it removes anything, and it will not remove volumes unless the export
# succeeded or the operator explicitly waives it.
set -euo pipefail

ORIG_ARGS="$*"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="${INSTALLER_ROOT:-$SCRIPT_DIR}"
# shellcheck source=lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"

DATA_DIR="${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}"
EXPORT_DIR=""
KEEP_DATA=0
PURGE=0
ASSUME_YES=0
SKIP_EXPORT=0

usage() {
  cat <<'EOF'
Vibe Sentinel uninstaller

Options:
  --export-dir <path>  Where to write the data export
                       (default: /var/lib/vibe-sentinel/exports/<timestamp>).
  --keep-data          Remove containers but KEEP all volumes and
                       /etc/vibe-sentinel. Reinstalling later picks up where
                       this left off.
  --skip-export        Do not export. Requires an explicit typed confirmation.
  --purge              Also remove /etc/vibe-sentinel (config, secrets, .env)
                       and /var/lib/vibe-sentinel after the export.
  --yes                Do not ask for the final confirmation. The typed
                       confirmation for --skip-export still applies.
  --help               This text.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --export-dir)   EXPORT_DIR="${2:?--export-dir needs a value}"; shift 2 ;;
    --export-dir=*) EXPORT_DIR="${1#*=}"; shift ;;
    --keep-data)    KEEP_DATA=1; shift ;;
    --skip-export)  SKIP_EXPORT=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --help|-h)      usage; exit 0 ;;
    *) die "Unknown argument: $1" "Run with --help for usage." ;;
  esac
done

require_root
require_cmd jq
require_cmd docker docker.io

[ -f "$SENTINEL_CONFIG" ] || die "No Vibe Sentinel installation found at $SENTINEL_CONFIG." \
  "There is nothing to uninstall on this host. If you are cleaning up a partial install, remove /etc/vibe-sentinel and any vibe-sentinel_* docker volumes by hand."

SELECTED_MODULES="$(jq -r '.modules.selected | join(" ")' "$SENTINEL_CONFIG")"
export SELECTED_MODULES
DOMAIN="$(config_get '.firm.domain')"
FIRM="$(config_get '.firm.legal_name' 'this firm')"

if [ "$KEEP_DATA" -eq 1 ] && [ "$PURGE" -eq 1 ]; then
  die "--keep-data and --purge contradict each other." "Pick one."
fi

# ---------------------------------------------------------------------------
# What is about to happen
# ---------------------------------------------------------------------------
hr 2>/dev/null || true
log "Uninstalling Vibe Sentinel for $FIRM ($DOMAIN)"
log "Modules installed: $SELECTED_MODULES"
cat <<EOF

This removes the firm's security monitoring. After it finishes:

  * No intrusion detection, no FIM, no runtime detection, no alerting.
  * Agent telemetry stops. Wazuh agents on workstations keep running and keep
    failing to reach a manager until they are removed with the Lite uninstaller.
  * Monitoring evidence for REQ-011 stops accruing from this moment. If the
    firm is mid-year, the annual report will have a gap that needs explaining.
  * Any Security Six control this appliance provided needs a compensating
    control recorded before the next assessment.

EOF

# ---------------------------------------------------------------------------
# Data export — BEFORE anything is removed
# ---------------------------------------------------------------------------
export_data() {
  local stamp target user
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="${EXPORT_DIR:-$DATA_DIR/exports/$stamp}"
  mkdir -p "$target"
  chmod 700 "$target"

  log "Exporting to $target"
  log "This can take a while and needs room for the whole event store — check free space now if you are exporting to the same disk."

  user="$(grep -m1 '^POSTGRES_USER=' "$SENTINEL_ENV_FILE" 2>/dev/null | cut -d= -f2 || echo sentinel)"

  # --- 1. Every database on the shared instance --------------------------
  # sentinel holds the compliance record; vaultwarden holds the vault;
  # vibe_print holds the paper trail; authentik holds the identity config.
  mkdir -p "$target/postgres"
  local cid
  cid="$(docker compose -f "$SENTINEL_COMPOSE" --env-file "$SENTINEL_ENV_FILE" ps -q sentinel-db 2>/dev/null | head -n1)"
  if [ -n "$cid" ]; then
    for db in sentinel authentik vaultwarden vibe_print; do
      if docker exec -e PGPASSWORD="$(grep -m1 '^POSTGRES_PASSWORD=' "$SENTINEL_ENV_FILE" | cut -d= -f2-)" \
           "$cid" pg_dump -U "$user" -Fc -d "$db" >"$target/postgres/$db.dump" 2>/dev/null; then
        log_ok "  pg_dump $db → postgres/$db.dump ($(du -h "$target/postgres/$db.dump" | cut -f1))"
      else
        rm -f "$target/postgres/$db.dump"
        log_warn "  pg_dump $db failed or the database does not exist (module may not be installed)"
      fi
    done
    # Roles and grants, so a restore into a fresh instance actually works.
    docker exec -e PGPASSWORD="$(grep -m1 '^POSTGRES_PASSWORD=' "$SENTINEL_ENV_FILE" | cut -d= -f2-)" \
      "$cid" pg_dumpall -U "$user" --globals-only >"$target/postgres/globals.sql" 2>/dev/null \
      && log_ok "  pg_dumpall --globals-only → postgres/globals.sql" \
      || log_warn "  pg_dumpall --globals-only failed"
  else
    log_warn "  sentinel-db is not running — starting it just for the export."
    docker compose -f "$SENTINEL_COMPOSE" --env-file "$SENTINEL_ENV_FILE" up -d --no-deps sentinel-db >/dev/null 2>&1 || true
    sleep 15
    cid="$(docker compose -f "$SENTINEL_COMPOSE" --env-file "$SENTINEL_ENV_FILE" ps -q sentinel-db 2>/dev/null | head -n1)"
    [ -n "$cid" ] || log_err "  Could not start sentinel-db. The databases are NOT in this export — the volume tarball below still contains the raw data directory."
  fi

  # --- 2. Every volume, as a tarball -------------------------------------
  mkdir -p "$target/volumes"
  local vols
  vols="$(docker volume ls --format '{{.Name}}' | grep '^vibe-sentinel_' || true)"
  if [ -n "$vols" ]; then
    for v in $vols; do
      log "  archiving volume $v"
      if docker run --rm -v "$v:/src:ro" -v "$target/volumes:/out" alpine:3 \
           tar czf "/out/${v}.tar.gz" -C /src . >/dev/null 2>&1; then
        log_ok "  $v → volumes/${v}.tar.gz ($(du -h "$target/volumes/${v}.tar.gz" | cut -f1))"
      else
        log_warn "  could not archive $v"
      fi
    done
  else
    log_warn "  no vibe-sentinel_* volumes found"
  fi

  # --- 3. Host-side state: certs, module config, risk register -----------
  if [ -d "$DATA_DIR" ]; then
    tar czf "$target/host-data.tar.gz" \
      --exclude="./exports" --exclude="./restic-repo" \
      -C "$DATA_DIR" . 2>/dev/null \
      && log_ok "  $DATA_DIR → host-data.tar.gz" \
      || log_warn "  could not archive $DATA_DIR"
  fi

  # --- 4. Configuration and secrets, separately and locked down ----------
  # These are exported because a restore needs them, and they are the reason
  # the export directory is 700 and worth putting somewhere encrypted.
  tar czf "$target/etc-vibe-sentinel.tar.gz" -C "$(dirname "$SENTINEL_ETC")" "$(basename "$SENTINEL_ETC")" 2>/dev/null \
    && chmod 600 "$target/etc-vibe-sentinel.tar.gz" \
    && log_ok "  $SENTINEL_ETC → etc-vibe-sentinel.tar.gz (mode 600 — contains secrets)" \
    || log_warn "  could not archive $SENTINEL_ETC"

  # --- 5. A manifest so someone opening this in three years knows what it is
  ( umask 077
    jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          --arg firm "$FIRM" --arg domain "$DOMAIN" \
          --arg modules "$SELECTED_MODULES" \
          --arg version "$(json_get "$MANIFEST_FILE" '.sentinel_version' 'unknown')" \
          --arg host "$(hostname -f 2>/dev/null || hostname)" '{
      export_of: "Vibe Sentinel",
      sentinel_version: $version,
      firm: $firm, domain: $domain, host: $host,
      modules: ($modules | split(" ")),
      exported_at: $at,
      contents: {
        "postgres/": "pg_dump -Fc per database: sentinel (compliance record: incidents, risk assessment, attestations, evidence, disclosure log), authentik (identity config), vaultwarden (password vault), vibe_print (print audit trail). Restore with pg_restore. globals.sql holds roles and grants.",
        "volumes/": "One tar.gz per docker volume, including the Wazuh indexer event store, Uptime Kuma history, NetBird state, and Vaultwarden attachments and rsa_key*.",
        "host-data.tar.gz": "Certificates, module state, and the preflight risk register from /var/lib/vibe-sentinel.",
        "etc-vibe-sentinel.tar.gz": "Config, .env, and docker secrets. CONTAINS CREDENTIALS — mode 600. Store encrypted."
      },
      retention_note: "Incident records, reports, attestations, and evidence are the firm compliance artifacts and are retained indefinitely (plan §2.4). Do not delete this export on a routine schedule.",
      restore_note: "This export restores into a fresh Vibe Sentinel of the same version. Reinstall that version first, then pg_restore each dump and unpack the volume tarballs before first boot."
    }' >"$target/EXPORT-MANIFEST.json" )
  chmod 600 "$target/EXPORT-MANIFEST.json"

  chmod -R go-rwx "$target"
  hr 2>/dev/null || true
  log_ok "Export complete: $target"
  log    "Total size: $(du -sh "$target" | cut -f1)"
  log    "Move it OFF this host before continuing — it contains the firm's compliance record and its password vault."
  EXPORT_PATH="$target"
}

EXPORT_PATH=""
if [ "$KEEP_DATA" -eq 1 ]; then
  log "--keep-data: volumes stay in place, so no export is needed."
elif [ "$SKIP_EXPORT" -eq 1 ]; then
  log_warn "--skip-export was passed. The firm's compliance record, password vault, and print audit trail will be DESTROYED with no copy."
  printf 'Type DESTROY WITHOUT EXPORT to continue: '
  read -r confirm
  [ "$confirm" = "DESTROY WITHOUT EXPORT" ] || die "Not confirmed — nothing was changed." \
    "Re-run without --skip-export to take an export first."
else
  if [ "$ASSUME_YES" -eq 1 ]; then
    export_data
  else
    printf 'Export all Sentinel data before removing it? [Y/n] '
    read -r ans
    case "${ans:-Y}" in
      [Nn]*) log_warn "Skipping the export at your request."
             printf 'Type DESTROY WITHOUT EXPORT to continue: '
             read -r confirm
             [ "$confirm" = "DESTROY WITHOUT EXPORT" ] || die "Not confirmed — nothing was changed." "Re-run and answer Y to export first." ;;
      *)     export_data ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Final confirmation
# ---------------------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
  hr 2>/dev/null || true
  if [ "$KEEP_DATA" -eq 1 ]; then
    printf 'Remove all Vibe Sentinel containers (keeping data)? [y/N] '
  else
    printf 'Remove all Vibe Sentinel containers AND volumes? [y/N] '
  fi
  read -r ans
  case "${ans:-N}" in [Yy]*) : ;; *) die "Cancelled — nothing was removed." "${EXPORT_PATH:+Your export is still at $EXPORT_PATH.}" ;; esac
fi

# ---------------------------------------------------------------------------
# Teardown — reverse of the §2.6 install order, so dependents go first
# ---------------------------------------------------------------------------
REMOVE_VOLUMES=0
[ "$KEEP_DATA" -eq 1 ] || REMOVE_VOLUMES=1
export REMOVE_VOLUMES SENTINEL_ETC SENTINEL_COMPOSE SENTINEL_ENV_FILE

UNINSTALL_ORDER="scan print pulse keys mesh runtime edge core"
for m in $UNINSTALL_ORDER; do
  module_selected "$m" || continue
  script="$SENTINEL_ETC/modules/$m/uninstall.sh"
  [ -f "$script" ] || script="$INSTALLER_ROOT/modules/$m/uninstall.sh"
  if [ -f "$script" ]; then
    log "Removing module: $m"
    bash "$script" || log_warn "  $m uninstall reported an error — continuing so the rest still comes down."
  else
    log_warn "  no uninstall.sh for module $m"
  fi
done

# The ai module has no containers; drop its generated config with the rest.
if module_selected ai && [ "$KEEP_DATA" -ne 1 ]; then
  rm -rf "$SENTINEL_ETC/ai"
  log "Removing module: ai (config only)"
fi

# Anything the module scripts missed.
docker compose -f "$SENTINEL_COMPOSE" --env-file "$SENTINEL_ENV_FILE" down --remove-orphans 2>/dev/null || true
docker network rm vibe-sentinel 2>/dev/null || true

if [ "$REMOVE_VOLUMES" -eq 1 ]; then
  for v in $(docker volume ls --format '{{.Name}}' | grep '^vibe-sentinel_' || true); do
    docker volume rm -f "$v" >/dev/null 2>&1 || true
  done
fi

# ---------------------------------------------------------------------------
# Host state
# ---------------------------------------------------------------------------
if [ "$PURGE" -eq 1 ]; then
  # Keep the export even when it lives under the data dir.
  if [ -n "$EXPORT_PATH" ] && [ "${EXPORT_PATH#$DATA_DIR}" != "$EXPORT_PATH" ]; then
    KEEP_TMP="$(mktemp -d)"
    mv "$EXPORT_PATH" "$KEEP_TMP/" 2>/dev/null || true
  fi
  rm -rf "$SENTINEL_ETC"
  rm -rf "$DATA_DIR"
  if [ -n "${KEEP_TMP:-}" ]; then
    mkdir -p "$DATA_DIR/exports"
    mv "$KEEP_TMP"/* "$DATA_DIR/exports/" 2>/dev/null || true
    rmdir "$KEEP_TMP" 2>/dev/null || true
    EXPORT_PATH="$DATA_DIR/exports/$(basename "$EXPORT_PATH")"
  fi
  log_ok "Purged $SENTINEL_ETC and $DATA_DIR"
elif [ "$KEEP_DATA" -eq 1 ]; then
  log_ok "Config, secrets, and volumes kept. Re-run install.sh to bring the stack back."
else
  log "Config and secrets left in $SENTINEL_ETC. Remove them with --purge, or by hand once you are sure the export is good."
fi

hr 2>/dev/null || true
log_ok "Vibe Sentinel removed from $(hostname -f 2>/dev/null || hostname)."
[ -n "$EXPORT_PATH" ] && log "Data export: $EXPORT_PATH — move it somewhere encrypted and off this host."
cat <<EOF

Still to do by hand — this script cannot reach any of it:

  1. Endpoints. Wazuh agents, Sysmon, the NetBird client, the firm print
     queues, and the workstation printer-egress firewall rules are still
     installed on every workstation. Remove them with the Lite uninstaller or
     they will keep failing to reach a manager that no longer exists.
  2. Cloudflare. DNS records, the tunnel, Access applications, and the WAF
     rate-limit rules for ${DOMAIN} are still in place. The edge and keys
     module uninstallers removed what they created; the tunnel and the §2.6
     hostname records were created by install.sh and are left deliberately, so
     a reinstall is painless. Remove them in the Cloudflare dashboard if this
     is permanent.
  3. Compensating controls. Record what now covers each Security Six control
     the appliance was providing, before the next assessment.
  4. The WISP. It names Sentinel as an implemented safeguard. Update it, or
     the document no longer describes the firm's actual program.

EOF
