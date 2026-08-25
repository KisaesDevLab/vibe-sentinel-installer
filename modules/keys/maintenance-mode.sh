#!/usr/bin/env bash
# modules/keys/maintenance-mode.sh — the ONLY supported way to open the
# Vaultwarden /admin panel (§2.2, Phase 7K).
#
# In production ADMIN_TOKEN is unset, so /admin does not exist. When the QI
# genuinely needs it, this opens a window that:
#   * sets ADMIN_TOKEN to an argon2id PHC hash (never a plaintext token),
#   * recreates the container so it takes effect,
#   * schedules an automatic revert 30 minutes later (systemd-run, or `at`),
#   * writes a marker file the Sentinel API polls and turns into a change
#     record — open, approver, reason, expiry, and later the revert proof.
#
# The one-time plaintext token is printed ONCE, to the operator's terminal
# only, and is never written to disk or to the install log.
#
# Usage:
#   maintenance-mode.sh --on  [--reason "..."] [--approver "QI name"] [--minutes 30]
#   maintenance-mode.sh --off
#   maintenance-mode.sh --status
set -euo pipefail

SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
INSTALLER_ROOT="${INSTALLER_ROOT:-/opt/vibe-sentinel-installer}"
[ -f "$INSTALLER_ROOT/lib/common.sh" ] || INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/vibe-sentinel-installer"
# shellcheck source=../../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"
# shellcheck source=../../lib/health.sh
. "$INSTALLER_ROOT/lib/health.sh"
# shellcheck source=../../lib/compose-merge.sh
. "$INSTALLER_ROOT/lib/compose-merge.sh"

require_root

DATA_DIR="${SENTINEL_DATA_DIR:-/var/lib/vibe-sentinel}"
KEYS_DIR="$DATA_DIR/keys"
MARKER="$KEYS_DIR/maintenance-mode.json"
LAST="$KEYS_DIR/maintenance-mode.last.json"
UNIT="vibe-sentinel-keys-maintenance-revert"
SELF="$SENTINEL_ETC/modules/keys/maintenance-mode.sh"
[ -f "$SELF" ] || SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maintenance-mode.sh"

ACTION=""
REASON=""
APPROVER=""
MINUTES=30

while [ $# -gt 0 ]; do
  case "$1" in
    --on)       ACTION=on; shift ;;
    --off)      ACTION=off; shift ;;
    --status)   ACTION=status; shift ;;
    --reason)   REASON="${2:?--reason needs a value}"; shift 2 ;;
    --approver) APPROVER="${2:?--approver needs a value}"; shift 2 ;;
    --minutes)  MINUTES="${2:?--minutes needs a value}"; shift 2 ;;
    --help|-h)  sed -n '2,26p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" "Run with --help for usage." ;;
  esac
done
[ -n "$ACTION" ] || die "Nothing to do." "Pass --on, --off, or --status. Run with --help for usage."

# The auto-revert is the whole point of the control; refuse a window we cannot
# guarantee will close on its own.
if [ "$MINUTES" -gt 30 ] 2>/dev/null; then
  die "Maintenance windows are capped at 30 minutes." \
      "The 30-minute auto-revert is the compensating control for enabling /admin at all. If you need longer, close this window and open a second one — each is its own change record."
fi

SELECTED_MODULES="$(jq -r '.modules.selected | join(" ")' "$SENTINEL_CONFIG")"
export SELECTED_MODULES

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
env_unset_admin_token() {
  sed -i '/^ADMIN_TOKEN=/d' "$SENTINEL_ENV_FILE"
  chmod 600 "$SENTINEL_ENV_FILE"
}

env_set_admin_token() { # phc-hash
  env_unset_admin_token
  # Single-quoted: the compose dotenv parser expands ${...} and $NAME inside
  # unquoted or double-quoted values, and an argon2id PHC string is nothing but
  # dollar-delimited fields ($argon2id$v=19$m=...). Single quotes keep it literal.
  printf "ADMIN_TOKEN='%s'\n" "$1" >>"$SENTINEL_ENV_FILE"
  chmod 600 "$SENTINEL_ENV_FILE"
}

# The merged /etc/vibe-sentinel/compose.yml is fully resolved at merge time, so
# changing .env alone is not enough — the compose has to be re-merged, exactly
# as install.sh does when it rebinds MESH_BIND_IP.
apply() {
  merge_compose
  compose_cmd up -d --force-recreate --no-deps vaultwarden
  wait_healthy "Vaultwarden" 180 \
    "Vaultwarden did not come back healthy after the change. Check: docker compose logs vaultwarden" \
    check_container_healthy vaultwarden
}

admin_token_present_on_container() {
  local cid
  cid="$(compose_cmd ps -q vaultwarden 2>/dev/null | head -n1)"
  [ -n "$cid" ] || return 1
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null \
    | grep -q '^ADMIN_TOKEN=\$argon2'
}

schedule_revert() { # minutes
  local mins="$1"
  # Cancel any previously scheduled revert so re-opening does not leave two.
  systemctl stop "${UNIT}.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
  atrm $(cat "$KEYS_DIR/.at-job" 2>/dev/null) >/dev/null 2>&1 || true
  rm -f "$KEYS_DIR/.at-job"

  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --quiet --unit="$UNIT" --on-active="${mins}min" \
      --description="Vibe Sentinel: auto-revert Vaultwarden maintenance mode" \
      /bin/bash "$SELF" --off
    printf 'systemd-run:%s' "$UNIT"
    return 0
  fi
  if command -v at >/dev/null 2>&1; then
    local job
    job="$(printf '/bin/bash %s --off\n' "$SELF" | at now + "$mins" minutes 2>&1 | awk '/^job/ {print $2}')"
    [ -n "$job" ] || return 1
    printf '%s' "$job" >"$KEYS_DIR/.at-job"
    printf 'at:%s' "$job"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
case "$ACTION" in
  status)
    if [ -s "$MARKER" ]; then
      jq . "$MARKER"
      admin_token_present_on_container \
        && log_ok "/admin is ENABLED on the container (window open)" \
        || log_warn "Marker says open but the container has no ADMIN_TOKEN — run --off to reconcile."
    else
      log_ok "/admin is disabled at rest (no maintenance window open)."
      [ -s "$LAST" ] && { echo "Last window:"; jq . "$LAST"; }
    fi
    exit 0
    ;;

  on)
    [ -n "$REASON" ]   || die "A maintenance window needs a reason." \
      "Re-run with --reason \"why /admin is needed\". The reason goes into the change record; a window without one is not auditable."
    [ -n "$APPROVER" ] || APPROVER="$(config_get '.firm.qi_name')"
    [ -n "$APPROVER" ] || die "No approver recorded and no QI name in the config." \
      "Re-run with --approver \"QI name\"."
    command -v argon2 >/dev/null 2>&1 || die "The 'argon2' CLI is not installed." \
      "Install it with: apt-get install -y argon2 — ADMIN_TOKEN is only ever stored as an argon2id hash, never in plaintext."

    if [ -s "$MARKER" ]; then
      log_warn "A maintenance window is already open (expires $(jq -r '.expires_at' "$MARKER")). Re-opening resets the clock."
    fi

    mkdir -p "$KEYS_DIR"; chmod 700 "$KEYS_DIR"

    TOKEN="$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48)"
    SALT="$(openssl rand -base64 32)"
    # Parameters from the Vaultwarden documentation for ADMIN_TOKEN hashes.
    HASH="$(printf '%s' "$TOKEN" | argon2 "$SALT" -e -id -k 65540 -t 3 -p 4)"
    case "$HASH" in
      \$argon2id\$*) : ;;
      *) die "argon2 did not produce a PHC hash." "Check that the installed 'argon2' binary supports -e -id." ;;
    esac

    OPENED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    EXPIRES_AT="$(date -u -d "+${MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

    env_set_admin_token "$HASH"
    apply

    if ! admin_token_present_on_container; then
      log_err "ADMIN_TOKEN did not reach the container — reverting rather than leaving an unknown state."
      env_unset_admin_token
      apply
      die "Could not open the maintenance window." \
          "The argon2 hash was not passed through to the container. Verify ADMIN_TOKEN in $SENTINEL_ENV_FILE is single-quoted and re-run."
    fi

    if REVERT="$(schedule_revert "$MINUTES")"; then
      log_ok "Auto-revert scheduled ($REVERT) for $EXPIRES_AT"
    else
      log_err "Neither systemd-run nor at is available to schedule the auto-revert — closing the window now."
      env_unset_admin_token
      apply
      die "Cannot guarantee the 30-minute auto-revert on this host." \
          "Install one of: systemd (systemd-run) or the 'at' package (apt-get install -y at), then re-run. An /admin window that does not close by itself is not an approved control."
    fi

    ( umask 077
      jq -n --arg state open --arg opened_at "$OPENED_AT" --arg expires_at "$EXPIRES_AT" \
            --arg reason "$REASON" --arg approver "$APPROVER" \
            --arg opened_by "${SUDO_USER:-root}" --arg revert "$REVERT" \
            --argjson minutes "$MINUTES" '{
        module: "keys",
        subject: "vaultwarden-admin-panel",
        state: $state,
        opened_at: $opened_at,
        expires_at: $expires_at,
        window_minutes: $minutes,
        reason: $reason,
        approver: $approver,
        opened_by: $opened_by,
        revert_scheduled_via: $revert,
        change_record: "pending",
        note: "ADMIN_TOKEN is stored only as an argon2id hash. Sentinel API turns this marker into a change record and asserts the revert."
      }' >"$MARKER" )
    chmod 600 "$MARKER"

    hr 2>/dev/null || true
    log_ok "Vaultwarden /admin is OPEN until $EXPIRES_AT (${MINUTES} min)."
    printf '\n  URL:   %s/admin\n  Token: %s\n\n' "$(config_get '.firm.domain' | sed 's#^#https://vault.#')" "$TOKEN"
    log "This token is shown once and is not stored anywhere. It stops working at the auto-revert."
    log "Close early with: bash $SELF --off"
    ;;

  off)
    CLOSED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    systemctl stop "${UNIT}.timer" >/dev/null 2>&1 || true
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    if [ -s "$KEYS_DIR/.at-job" ]; then
      atrm "$(cat "$KEYS_DIR/.at-job")" >/dev/null 2>&1 || true
      rm -f "$KEYS_DIR/.at-job"
    fi

    env_unset_admin_token
    apply

    if admin_token_present_on_container; then
      die "ADMIN_TOKEN is STILL set on the vaultwarden container after the revert." \
          "Stop the container and inspect $SENTINEL_ENV_FILE and $SENTINEL_COMPOSE by hand — the /admin panel must not stay reachable."
    fi

    mkdir -p "$KEYS_DIR"; chmod 700 "$KEYS_DIR"
    if [ -s "$MARKER" ]; then
      ( umask 077
        jq --arg closed_at "$CLOSED_AT" --arg by "${SUDO_USER:-auto-revert}" \
           '.state = "closed" | .closed_at = $closed_at | .closed_by = $by | .revert_verified = true' \
           "$MARKER" >"$LAST" )
      rm -f "$MARKER"
    else
      ( umask 077
        jq -n --arg closed_at "$CLOSED_AT" --arg by "${SUDO_USER:-auto-revert}" '{
          module:"keys", subject:"vaultwarden-admin-panel", state:"closed",
          closed_at:$closed_at, closed_by:$by, revert_verified:true,
          note:"Closed with no open marker — /admin confirmed disabled."
        }' >"$LAST" )
    fi
    chmod 600 "$LAST"
    log_ok "Vaultwarden /admin disabled; ADMIN_TOKEN removed and verified absent on the container."
    log    "Revert proof written to $LAST for the change record."
    ;;
esac
