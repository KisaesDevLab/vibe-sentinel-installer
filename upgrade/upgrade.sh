#!/usr/bin/env bash
# upgrade/upgrade.sh — move a running Vibe Sentinel appliance to a target
# version (plan §2.5 "upgrade/ — versioned migrations for every module;
# pre-upgrade Vault snapshot", Phase 18).
#
#   sudo bash upgrade/upgrade.sh 0.2.0
#   sudo bash upgrade/upgrade.sh 0.2.0 --dry-run
#
# Order of operations, and why:
#
#   1. PLAN      Diff the deployed image set against the target manifest and
#                print exactly what will change. Nothing is touched yet.
#   2. GATE      Refuse the upgrade outright if a harness-gated image
#                (Uptime Kuma, Vaultwarden, NetBird, Authentik, Wazuh) moves to
#                a version the harness has not passed. See the reasoning in
#                versions/manifest.json → harness_gating.
#   3. SNAPSHOT  Take a pre-upgrade backup — Vibe Vault if the firm runs it,
#                the built-in restic job if not. An upgrade without a restore
#                point is not an upgrade, it is a gamble with the firm's
#                compliance record.
#   4. STOP      Bring the stack down. Migrations run against a stopped stack
#                so nothing writes underneath them.
#   5. MIGRATE   Run each selected module's migrate/NNN-*.sh in order.
#   6. START     Re-render .env and compose from the target manifest, then
#                bring services up in the §2.6 first-boot order with the same
#                health gates install.sh uses.
#   7. VERIFY    Run every module's healthcheck.sh. A failure here halts loudly
#                with the restore command, rather than leaving a half-upgraded
#                stack that looks fine from the outside.
set -euo pipefail

ORIG_ARGS="$*"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="${INSTALLER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"
# shellcheck source=../lib/health.sh
. "$INSTALLER_ROOT/lib/health.sh"
# shellcheck source=../lib/secrets.sh
. "$INSTALLER_ROOT/lib/secrets.sh"
# shellcheck source=../lib/compose-merge.sh
. "$INSTALLER_ROOT/lib/compose-merge.sh"

DEPLOYED_MANIFEST="$SENTINEL_ETC/versions/manifest.json"
UPGRADE_LOG_DIR="${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}/upgrades"

TARGET=""
DRY_RUN=0
SKIP_SNAPSHOT=0

usage() {
  cat <<'EOF'
Vibe Sentinel upgrade

  upgrade.sh <target-version> [options]

Options:
  --dry-run          Print the plan and the gate result, change nothing.
  --skip-snapshot    Skip the pre-upgrade backup. Requires an explicit
                     confirmation and is recorded in the upgrade log.
  --help             This text.

The installer checkout must already be at the target version (git checkout
v<target>); this script upgrades the RUNNING STACK to match it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --skip-snapshot) SKIP_SNAPSHOT=1; shift ;;
    --help|-h)       usage; exit 0 ;;
    -*)              die "Unknown argument: $1" "Run with --help for usage." ;;
    *)               [ -z "$TARGET" ] || die "Only one target version may be given (got '$TARGET' and '$1')." "Run with --help for usage."
                     TARGET="$1"; shift ;;
  esac
done

[ -n "$TARGET" ] || { usage; die "No target version given." "Run: sudo bash upgrade/upgrade.sh <target-version>"; }
[ "$DRY_RUN" -eq 1 ] || require_root

[ -f "$SENTINEL_CONFIG" ] || die "No Sentinel installation found at $SENTINEL_CONFIG." \
  "This host has nothing to upgrade. Run install.sh first."

require_cmd jq
require_cmd docker docker.io

SELECTED_MODULES="$(jq -r '.modules.selected | join(" ")' "$SENTINEL_CONFIG")"
export SELECTED_MODULES

# ---------------------------------------------------------------------------
# 0. Is the checkout actually at the target version?
# ---------------------------------------------------------------------------
MANIFEST_VERSION="$(json_get "$MANIFEST_FILE" '.sentinel_version')"
if [ "$MANIFEST_VERSION" != "$TARGET" ]; then
  die "The installer checkout is at version '$MANIFEST_VERSION' but you asked to upgrade to '$TARGET'." \
      "Move the checkout to the target first, then re-run:
     git -C $INSTALLER_ROOT fetch --tags
     git -C $INSTALLER_ROOT checkout v$TARGET
     sudo bash $INSTALLER_ROOT/upgrade/upgrade.sh $TARGET
   The manifest that ships with a tag is what defines that version — never hand-edit it to make this check pass."
fi

# First upgrade on a host installed before manifests were snapshotted: seed the
# deployed manifest from what is actually running, so the diff is real.
mkdir -p "$(dirname "$DEPLOYED_MANIFEST")"
if [ ! -s "$DEPLOYED_MANIFEST" ]; then
  log_warn "No deployed manifest at $DEPLOYED_MANIFEST — seeding it from the running stack."
  cp "$MANIFEST_FILE" "$DEPLOYED_MANIFEST"
  # Overwrite each ref with what the running containers actually use, so a
  # seeded manifest never claims an upgrade already happened.
  for key in $(jq -r '.images | keys[]' "$DEPLOYED_MANIFEST"); do
    envkey="IMG_$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')"
    running="$(grep -m1 "^${envkey}=" "$SENTINEL_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    [ -n "$running" ] || continue
    tmp="$(mktemp)"
    jq --arg k "$key" --arg r "$running" '.images[$k].deployed_ref = $r' "$DEPLOYED_MANIFEST" >"$tmp" && mv "$tmp" "$DEPLOYED_MANIFEST"
  done
  chmod 600 "$DEPLOYED_MANIFEST"
fi
DEPLOYED_VERSION="$(json_get "$DEPLOYED_MANIFEST" '.sentinel_version' 'unknown')"

# ---------------------------------------------------------------------------
# 1. Plan — what actually changes
# ---------------------------------------------------------------------------
hr 2>/dev/null || true
log "Upgrade plan: $DEPLOYED_VERSION → $TARGET (modules: $SELECTED_MODULES)"

CHANGED_IMAGES=""
image_ref_for() { # manifest-file key
  jq -r --arg k "$2" '
    .images[$k] as $i
    | if $i == null then empty
      elif ($i.digest // "" | startswith("sha256:TODO")) then ($i.repo + ":" + $i.tag)
      else ($i.repo + "@" + $i.digest) end' "$1"
}

for key in $(jq -r '.images | keys[]' "$MANIFEST_FILE"); do
  new_ref="$(image_ref_for "$MANIFEST_FILE" "$key")"
  old_ref="$(jq -r --arg k "$key" '.images[$k].deployed_ref // empty' "$DEPLOYED_MANIFEST")"
  [ -n "$old_ref" ] || old_ref="$(image_ref_for "$DEPLOYED_MANIFEST" "$key")"
  if [ "$new_ref" != "$old_ref" ]; then
    printf '  %-28s %s  →  %s\n' "$key" "${old_ref:-(new)}" "$new_ref"
    CHANGED_IMAGES="$CHANGED_IMAGES $key"
  fi
done
CHANGED_IMAGES="${CHANGED_IMAGES# }"
[ -n "$CHANGED_IMAGES" ] || log "  (no image changes — this is a migration-only upgrade)"

# ---------------------------------------------------------------------------
# 2. THE HARNESS GATE
#
# Five families are gated because a break in them is SILENT, not loud:
#   uptime-kuma  unversioned socket.io API — monitors quietly stop being managed
#   vaultwarden  one-way schema migration over the firm's entire credential set
#   netbird      every agent's only path home
#   authentik    the IdP the Sentinel UI depends on
#   wazuh        the detection engine itself; a broken decoder set reads as "quiet"
#
# There is no --force. A gate you can wave through is not a gate; the way past
# it is to run the harness against the target version and set harness_passed.
# ---------------------------------------------------------------------------
GATE_BLOCKED=""
for key in $CHANGED_IMAGES; do
  gated="$(jq -r --arg k "$key" '.images[$k].harness_gated // false' "$MANIFEST_FILE")"
  [ "$gated" = "true" ] || continue
  passed="$(jq -r --arg k "$key" '.images[$k].harness_passed // false' "$MANIFEST_FILE")"
  if [ "$passed" != "true" ]; then
    tag="$(jq -r --arg k "$key" '.images[$k].tag // "?"' "$MANIFEST_FILE")"
    log_err "GATE: $key → $tag has not passed the harness (harness_passed: false)"
    GATE_BLOCKED="$GATE_BLOCKED $key"
  else
    log_ok "GATE: $key has passed the harness for the target version"
  fi
done

if [ -n "$GATE_BLOCKED" ]; then
  die "Upgrade refused: harness-gated images would move to unverified versions:${GATE_BLOCKED}" \
      "Run the detection/integration harness against the target version, then set
   .images[\"<name>\"].harness_passed = true in the TAGGED manifest and cut a new
   tag. Do not edit the manifest on this host to get past this — the whole point
   of the gate is that these five break silently:
     uptime-kuma  monitors stop being managed and nothing looks wrong
     vaultwarden  schema migration is one-way, over the firm's whole vault
     netbird      agents lose their only path home
     authentik    the Sentinel UI's IdP
     wazuh        the detection engine; a broken decoder set reads as 'quiet'
   To upgrade everything else now, cut a manifest that leaves these five pinned
   at their current versions and re-run."
fi

# Per-module migration steps that will run.
MIGRATION_STEPS=""
for m in $SELECTED_MODULES; do
  for step in "$INSTALLER_ROOT/modules/$m/migrate/"[0-9]*.sh; do
    [ -f "$step" ] || continue
    MIGRATION_STEPS="$MIGRATION_STEPS $step"
    printf '  migrate: %s/%s\n' "$m" "$(basename "$step")"
  done
done
[ -n "$MIGRATION_STEPS" ] || log "  (no module migration steps for this upgrade)"

if [ "$DRY_RUN" -eq 1 ]; then
  hr 2>/dev/null || true
  log_ok "Dry run complete. Nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Pre-upgrade snapshot — Vibe Vault, or the built-in restic job
# ---------------------------------------------------------------------------
mkdir -p "$UPGRADE_LOG_DIR"; chmod 700 "$UPGRADE_LOG_DIR"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD="$UPGRADE_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${DEPLOYED_VERSION}-to-${TARGET}.json"
SNAPSHOT_METHOD="none"
SNAPSHOT_ID=""

take_vault_snapshot() {
  local vault_cid
  vault_cid="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 'vibe-vault' || true)"
  [ -n "$vault_cid" ] || return 1
  log "Vibe Vault detected ($vault_cid) — requesting a pre-upgrade snapshot of every Sentinel dataset."
  docker exec "$vault_cid" vault-cli snapshot \
    --reason "pre-upgrade vibe-sentinel $DEPLOYED_VERSION -> $TARGET" \
    --tag sentinel-preupgrade || return 1
  SNAPSHOT_METHOD="vibe-vault"
  SNAPSHOT_ID="$(docker exec "$vault_cid" vault-cli snapshots --latest --json 2>/dev/null | jq -r '.id // empty' || true)"
  return 0
}

take_restic_snapshot() {
  # The built-in job (§2.4) normally runs on a timer inside its container. Here
  # we drive one immediately: dump every database, then back up the data dir.
  log "Taking a pre-upgrade restic snapshot with the built-in backup job."
  local workdir db
  workdir="$(mktemp -d)"
  for db in sentinel authentik vaultwarden vibe_print; do
    compose_cmd exec -T sentinel-db pg_dump -U "$(grep -m1 '^POSTGRES_USER=' "$SENTINEL_ENV_FILE" | cut -d= -f2)" \
      -Fc -d "$db" >"$workdir/$db.dump" 2>/dev/null \
      || log_warn "pg_dump $db failed (the database may not exist for the selected modules)"
  done
  compose_cmd --profile no-vault run --rm --no-deps \
    -v "$workdir:/preupgrade:ro" sentinel-backup \
    sh -c 'restic snapshots >/dev/null 2>&1 || restic init; restic backup --tag sentinel-preupgrade /preupgrade /data/sentinel' \
    || { rm -rf "$workdir"; return 1; }
  rm -rf "$workdir"
  SNAPSHOT_METHOD="restic-builtin"
  return 0
}

if [ "$SKIP_SNAPSHOT" -eq 1 ]; then
  log_warn "--skip-snapshot was passed. There will be NO restore point for this upgrade."
  printf 'Type UPGRADE WITHOUT BACKUP to continue: '
  read -r confirm
  [ "$confirm" = "UPGRADE WITHOUT BACKUP" ] || die "Not confirmed — nothing was changed." \
    "Re-run without --skip-snapshot."
  SNAPSHOT_METHOD="skipped-by-operator"
else
  if ! take_vault_snapshot; then
    log "No Vibe Vault on this host (or its snapshot failed) — falling back to the built-in restic job."
    take_restic_snapshot || die "Could not take a pre-upgrade snapshot." \
      "Fix the backup path before upgrading. An upgrade with no restore point puts the firm's compliance record at risk — this is the one step that is never optional. Check: docker compose --profile no-vault logs sentinel-backup"
  fi
  log_ok "Pre-upgrade snapshot taken via $SNAPSHOT_METHOD${SNAPSHOT_ID:+ (id $SNAPSHOT_ID)}"
fi

# ---------------------------------------------------------------------------
# 4. Stop the stack — migrations run against a stopped stack
# ---------------------------------------------------------------------------
log "Stopping services (containers only; volumes and networks are preserved)."
compose_cmd stop || true

# ---------------------------------------------------------------------------
# 5. Per-module migrations, in module order then step order
# ---------------------------------------------------------------------------
if [ -n "$MIGRATION_STEPS" ]; then
  log "Running module migrations."
  for step in $MIGRATION_STEPS; do
    log "  → $(basename "$(dirname "$(dirname "$step")")")/$(basename "$step")"
    if ! SENTINEL_ETC="$SENTINEL_ETC" INSTALLER_ROOT="$INSTALLER_ROOT" \
         FROM_VERSION="$DEPLOYED_VERSION" TO_VERSION="$TARGET" bash "$step"; then
      die "Migration step failed: $step" \
          "The stack is STOPPED and the data is untouched by anything after this step.
   Fix the cause and re-run the upgrade, or restore the pre-upgrade snapshot
   (method: $SNAPSHOT_METHOD${SNAPSHOT_ID:+, id $SNAPSHOT_ID}) and re-run at the old version.
   Migration steps are idempotent by contract, so a re-run is safe."
    fi
  done
  log_ok "All migration steps completed."
fi

# ---------------------------------------------------------------------------
# 6. Re-render and start
# ---------------------------------------------------------------------------
log "Re-staging modules and re-rendering .env and compose from the $TARGET manifest."
write_env_file
stage_modules
validate_env_schema
merge_compose

log "Pulling target images."
compose_cmd pull --quiet || log_warn "Some images could not be pulled — startup will fail if any are missing locally."

# §2.6 ordering, same gates install.sh uses.
up() { compose_cmd up -d --no-deps "$@"; }

up sentinel-db sentinel-redis
wait_healthy "Postgres (sentinel-db)" 300 \
  "Postgres did not come back after the upgrade. Restore the pre-upgrade snapshot before trying anything else; logs: docker compose logs sentinel-db" \
  check_pg_ready sentinel-db sentinel
wait_healthy "Redis (sentinel-redis)" 60 \
  "Redis did not come back — check container logs." \
  check_redis_ready sentinel-redis

up authentik-server authentik-worker
wait_healthy "Authentik" 420 \
  "Authentik did not come healthy after the upgrade. Authentik release trains rename settings between versions — check docker compose logs authentik-server." \
  check_http_ok "http://127.0.0.1:9000/-/health/ready/" insecure

up sentinel-certs
wait_healthy "Wildcard certificate" 300 \
  "The certs sidecar did not publish a wildcard certificate; logs: docker compose logs sentinel-certs" \
  check_file_exists "/var/lib/vibe-sentinel/certs/live/wildcard.crt"

up sentinel-api sentinel-worker sentinel-web
wait_healthy "Sentinel API" 420 \
  "sentinel-api failed its /healthz after the upgrade — its Drizzle migrations run on boot; logs: docker compose logs sentinel-api" \
  check_http_ok "http://127.0.0.1:8081/healthz"

up wazuh-indexer
wait_healthy "Wazuh indexer" 600 \
  "OpenSearch did not go green; logs: docker compose logs wazuh-indexer" \
  check_http_ok "https://127.0.0.1:9200/_cluster/health" insecure
up wazuh-manager
wait_healthy "Wazuh manager" 420 \
  "The Wazuh manager did not become healthy — docker compose logs wazuh-manager" \
  check_container_healthy wazuh-manager
up wazuh-dashboard
wait_healthy "Wazuh dashboard" 420 \
  "The Wazuh dashboard did not come up — docker compose logs wazuh-dashboard" \
  check_container_healthy wazuh-dashboard

up ntfy
wait_healthy "ntfy" 120 "ntfy failed to start — docker compose logs ntfy" check_container_healthy ntfy

if module_selected edge; then
  up crowdsec cs-firewall-bouncer
  wait_healthy "CrowdSec LAPI" 180 \
    "CrowdSec LAPI not answering on loopback :8080 — docker compose logs crowdsec" \
    check_http_ok "http://127.0.0.1:8080/health"
fi
if module_selected runtime; then
  up falco falcosidekick
  wait_healthy "Falco runtime detection" 240 \
    "Falco failed to load its probe — docker compose logs falco" \
    check_container_healthy falco
fi
if module_selected mesh; then
  up netbird-management netbird-signal netbird-dashboard
  wait_healthy "NetBird management/signal" 300 \
    "NetBird management or signal failed to start — every agent's path home runs through here; docker compose logs netbird-management netbird-signal" \
    check_all_healthy netbird-management netbird-signal
fi
if module_selected keys; then
  up vaultwarden
  wait_healthy "Vaultwarden" 300 \
    "Vaultwarden failed to start. Its schema migration is one-way — if this persists, restore the pre-upgrade snapshot rather than experimenting; logs: docker compose logs vaultwarden" \
    check_container_healthy vaultwarden
fi
if module_selected pulse; then
  up uptime-kuma
  wait_healthy "Uptime Kuma" 300 \
    "Uptime Kuma failed to start — docker compose logs uptime-kuma" \
    check_container_healthy uptime-kuma
fi
if module_selected print; then
  up vibe-print vibe-print-release vibe-print-scanner-inbox
  wait_healthy "Vibe Print gateway" 300 \
    "The Vibe Print gateway failed to start — docker compose logs vibe-print" \
    check_container_healthy vibe-print
fi
if module_selected scan; then
  up gb-pg gb-redis gb-mqtt gvmd ospd-openvas gsa
  wait_healthy "Greenbone (gvmd + web UI)" 900 \
    "Greenbone did not come healthy — a major version bump can force a multi-hour feed resync; logs: docker compose logs gvmd gsa" \
    check_container_healthy gsa
fi

# Config-only module: re-render after every upgrade.
if module_selected ai; then
  bash "$SENTINEL_ETC/modules/ai/setup.sh"
fi

# Print isolation rules are regenerated because interfaces may have moved.
if module_selected print && [ -x "$SENTINEL_ETC/modules/print/printer-network-policy.sh" ]; then
  bash "$SENTINEL_ETC/modules/print/printer-network-policy.sh" --apply || \
    log_warn "Printer network policy could not be re-applied — run it by hand; printers may be reachable from workstations until you do (SENT-PR-002)."
fi

# ---------------------------------------------------------------------------
# 7. Verify — every module's own healthcheck
# ---------------------------------------------------------------------------
hr 2>/dev/null || true
log "Post-upgrade verification."
VERIFY_FAILED=""
for m in $SELECTED_MODULES; do
  hc="$SENTINEL_ETC/modules/$m/healthcheck.sh"
  [ -f "$hc" ] || continue
  echo "--- $m ---"
  bash "$hc" || VERIFY_FAILED="$VERIFY_FAILED $m"
done

# Record the upgrade regardless of outcome — a failed upgrade is exactly the
# one you want a record of.
( umask 077
  jq -n --arg from "$DEPLOYED_VERSION" --arg to "$TARGET" \
        --arg started "$STARTED_AT" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg snapshot "$SNAPSHOT_METHOD" --arg snapshot_id "$SNAPSHOT_ID" \
        --arg modules "$SELECTED_MODULES" --arg changed "$CHANGED_IMAGES" \
        --arg failed "${VERIFY_FAILED# }" --arg by "${SUDO_USER:-root}" '{
    from_version: $from, to_version: $to,
    started_at: $started, finished_at: $finished,
    performed_by: $by,
    snapshot: { method: $snapshot, id: $snapshot_id },
    modules: ($modules | split(" ")),
    images_changed: ($changed | if . == "" then [] else split(" ") end),
    verification_failed: ($failed | if . == "" then [] else split(" ") end),
    result: (if $failed == "" then "success" else "verification_failed" end)
  }' >"$RECORD" )
chmod 600 "$RECORD"

# Snapshot the manifest that is now deployed, with the refs actually in use.
cp "$MANIFEST_FILE" "$DEPLOYED_MANIFEST"
for key in $(jq -r '.images | keys[]' "$DEPLOYED_MANIFEST"); do
  envkey="IMG_$(printf '%s' "$key" | tr 'a-z-' 'A-Z_')"
  running="$(grep -m1 "^${envkey}=" "$SENTINEL_ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$running" ] || continue
  tmp="$(mktemp)"
  jq --arg k "$key" --arg r "$running" '.images[$k].deployed_ref = $r' "$DEPLOYED_MANIFEST" >"$tmp" && mv "$tmp" "$DEPLOYED_MANIFEST"
done
chmod 600 "$DEPLOYED_MANIFEST"

if [ -n "$VERIFY_FAILED" ]; then
  die "Upgrade to $TARGET completed but verification FAILED for:${VERIFY_FAILED}" \
      "The stack is running at the new version with known-bad modules. Either fix the
   failures above, or roll back:
     1. git -C $INSTALLER_ROOT checkout v$DEPLOYED_VERSION
     2. restore the pre-upgrade snapshot (method: $SNAPSHOT_METHOD${SNAPSHOT_ID:+, id $SNAPSHOT_ID})
     3. sudo bash $INSTALLER_ROOT/install.sh --unattended --config $SENTINEL_CONFIG
   The upgrade record is at $RECORD."
fi

hr 2>/dev/null || true
log_ok "Vibe Sentinel upgraded: $DEPLOYED_VERSION → $TARGET. All module healthchecks passed."
log    "Upgrade record: $RECORD"
log    "Pre-upgrade restore point: $SNAPSHOT_METHOD${SNAPSHOT_ID:+ (id $SNAPSHOT_ID)}"
