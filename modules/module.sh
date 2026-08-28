#!/usr/bin/env bash
# modules/module.sh — turn a single module on or off after the initial install.
#
# install.sh selects modules once and brings the whole stack up in §2.6 order.
# This is the after-the-fact equivalent for ONE module, and it is what the Vibe
# Appliance's console calls when an operator clicks Enable or Disable on a
# Sentinel row (lib/sentinel-module.sh in that repo). It is equally usable by
# hand.
#
# Usage:
#   bash modules/module.sh enable  <id>
#   bash modules/module.sh disable <id> --reason "..." --approver "..."
#   bash modules/module.sh health  <id>
#   bash modules/module.sh status
#
# Idempotency: enabling an already-enabled module re-stages, re-merges and
#   re-runs the health gate — a converged module is a no-op that ends green.
#   Disabling an already-disabled module exits 0 without touching anything.
# Reverse operation: `enable` reverses `disable` and vice versa. Neither
#   removes volumes; data survives both. Removing data is uninstall.sh's job,
#   and it exports first.
#
# WHAT THIS REFUSES TO DO, and why:
#
#   * disable `core` — every other module depends on it, so turning it off is
#     tearing the appliance down. That is uninstall.sh, which exports the
#     firm's compliance artifacts before removing anything.
#   * disable a Security Six module (mesh/keys/pulse/print) without a recorded
#     compensating control. A firm may legitimately use Tailscale instead of
#     NetBird or 1Password instead of Vaultwarden, but the scorecard still needs
#     an answer, so "off" without a reason is refused rather than accepted.
#     The manifest's `disableRequires` is what marks those modules.
#   * enable a module whose requiredApps are not themselves enabled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_ROOT="${INSTALLER_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export INSTALLER_ROOT

# shellcheck source=../lib/common.sh
. "$INSTALLER_ROOT/lib/common.sh"
# shellcheck source=../lib/manifests.sh
. "$INSTALLER_ROOT/lib/manifests.sh"
# shellcheck source=../lib/health.sh
. "$INSTALLER_ROOT/lib/health.sh"
# shellcheck source=../lib/secrets.sh
. "$INSTALLER_ROOT/lib/secrets.sh"
# shellcheck source=../lib/compose-merge.sh
. "$INSTALLER_ROOT/lib/compose-merge.sh"

usage() {
  cat <<'HELP'
modules/module.sh — enable or disable one Sentinel module after install.

  enable  <id>                                 add the module and bring it up
  disable <id> --reason R --approver A         stop it; Security Six need both
  health  <id>                                 run the module's healthcheck
  status                                       list every module and its state

Disabling mesh / keys / pulse / print records a compensating control in
config.json — what the firm uses instead — because the compliance scorecard
still needs an answer. `core` cannot be disabled; use uninstall.sh, which
exports the firm's compliance artifacts first.
HELP
}

# --- selection state -------------------------------------------------------
# config.json's .modules.selected is the source of truth; SELECTED_MODULES is
# the in-process view install.sh and the preflights already read.
selected_modules() {
  [ -f "$SENTINEL_CONFIG" ] || { printf 'core'; return; }
  jq -r '(.modules.selected // ["core"]) | join(" ")' "$SENTINEL_CONFIG"
}

set_selected_modules() { # space-separated list
  local tmp
  tmp="$(mktemp "${SENTINEL_CONFIG}.XXXXXX")"
  jq --arg m "$1" '.modules.selected = ($m | split(" "))' "$SENTINEL_CONFIG" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SENTINEL_CONFIG"
}

record_compensating_control() { # id reason approver
  local tmp
  tmp="$(mktemp "${SENTINEL_CONFIG}.XXXXXX")"
  jq --arg id "$1" --arg reason "$2" --arg approver "$3" \
     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.compensating_controls = ((.compensating_controls // {}) + {($id): {reason: $reason, approver: $approver, recorded_at: $at}})' \
     "$SENTINEL_CONFIG" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SENTINEL_CONFIG"
}

require_installed() {
  [ -f "$SENTINEL_CONFIG" ] || die \
    "Sentinel is not installed on this host ($SENTINEL_CONFIG is missing)." \
    "Run 'sudo bash install.sh' first; this command changes an existing install."
}

require_known_module() { # id
  case " $ALL_MODULES " in
    *" $1 "*) : ;;
    *) die "Unknown module '$1'." "Valid modules: $ALL_MODULES" ;;
  esac
  [ -f "$(manifest_path "$1")" ] || die \
    "modules/$1 ships no manifest.json." \
    "That file carries the module's ports, resource floor and gates; without it this command cannot act safely. This is a packaging bug, not a host problem."
}

# Services a module contributes, from the merged compose minus core's.
module_services() { # id
  local all core
  all="$(docker compose --project-name vibe-sentinel --project-directory "$SENTINEL_ETC" \
        --env-file "$SENTINEL_ENV_FILE" \
        -f "$SENTINEL_ETC/modules/core/compose.yml" \
        -f "$SENTINEL_ETC/modules/$1/compose.yml" config --services 2>/dev/null | sort -u)"
  core="$(docker compose --project-name vibe-sentinel --project-directory "$SENTINEL_ETC" \
         --env-file "$SENTINEL_ENV_FILE" \
         -f "$SENTINEL_ETC/modules/core/compose.yml" config --services 2>/dev/null | sort -u)"
  [ -n "$all" ] && [ -n "$core" ] || return 0
  comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$core")
}

# --- enable ----------------------------------------------------------------
cmd_enable() { # id
  local id="$1"
  require_installed
  require_known_module "$id"

  local current; current="$(selected_modules)"
  SELECTED_MODULES="$current"; export SELECTED_MODULES

  # Hard dependencies first — a module whose requiredApps are off will start
  # and immediately fail, and the operator will read container logs to find out
  # something this check could have said in one sentence.
  local deps dep dep_id
  deps="$(manifest_field "$id" '" ".join(data.get("requiredApps") or [])')"
  for dep in $deps; do
    dep_id="${dep#sentinel-}"
    if ! module_selected "$dep_id"; then
      die "$id requires the '$dep_id' module, which is not enabled." \
          "Enable it first: sudo bash modules/module.sh enable $dep_id"
    fi
  done

  if module_selected "$id"; then
    log "Module '$id' is already enabled; re-staging and re-running its health gate."
  else
    SELECTED_MODULES="$(validate_module_list "$current $id")"
    export SELECTED_MODULES
    set_selected_modules "$SELECTED_MODULES"
    log_ok "Added '$id' to the selected modules: $SELECTED_MODULES"
  fi

  # Re-stage every selected module and re-merge. Merging the whole set rather
  # than just this one keeps /etc/vibe-sentinel/compose.yml a complete
  # description of the stack, which is what every other command reads.
  write_docker_secrets
  write_env_file
  stage_modules
  validate_env_schema
  merge_compose

  local services; services="$(module_services "$id" | tr '\n' ' ')"
  if [ -z "${services// /}" ]; then
    log_ok "Module '$id' contributes no containers (config-only); nothing to start."
    cmd_health "$id" || true
    return 0
  fi

  log "Starting: $services"
  # shellcheck disable=SC2086
  compose_cmd up -d --no-deps $services

  cmd_health "$id"
}

# --- disable ---------------------------------------------------------------
cmd_disable() { # id reason approver
  local id="$1" reason="${2:-}" approver="${3:-}"
  require_installed
  require_known_module "$id"

  [ "$id" != "core" ] || die \
    "core cannot be disabled — every other module depends on it." \
    "Turning it off IS tearing the appliance down, so that path is uninstall.sh, which exports the firm's compliance artifacts before removing anything: sudo bash uninstall.sh"

  local requires; requires="$(manifest_disable_requires "$id")"
  if [ "$requires" = "compensating-control" ]; then
    if [ -z "$reason" ] || [ -z "$approver" ]; then
      die "Disabling '$id' needs a recorded compensating control." \
          "It is one of the Security Six, so the scorecard still needs an answer for the control it provides - 'firm uses Tailscale', 'firm uses 1Password Business'. Re-run with: --reason \"<what the firm uses instead>\" --approver \"<name, role>\""
    fi
  fi

  local current; current="$(selected_modules)"
  SELECTED_MODULES="$current"; export SELECTED_MODULES
  if ! module_selected "$id"; then
    log_ok "Module '$id' is already disabled; nothing to do."
    return 0
  fi

  # Anything that requires this module must go first, or it is left running
  # against a dependency that is gone.
  local other other_deps
  for other in $current; do
    [ "$other" = "$id" ] && continue
    other_deps="$(manifest_field "$other" '" ".join(data.get("requiredApps") or [])')"
    case " $other_deps " in
      *" sentinel-$id "*)
        die "Module '$other' requires '$id'; disable it first." \
            "sudo bash modules/module.sh disable $other --reason ... --approver ..." ;;
    esac
  done

  local services; services="$(module_services "$id" | tr '\n' ' ')"
  if [ -n "${services// /}" ]; then
    log "Stopping: $services"
    # shellcheck disable=SC2086
    compose_cmd stop $services || log_warn "compose stop reported errors; continuing to remove"
    # shellcheck disable=SC2086
    compose_cmd rm -f $services || log_warn "compose rm reported errors; containers may already be gone"
  fi

  if [ "$requires" = "compensating-control" ]; then
    record_compensating_control "$id" "$reason" "$approver"
    log_ok "Compensating control recorded for '$id': $reason (approved by $approver)"
  fi

  local remaining=""
  for other in $current; do
    [ "$other" = "$id" ] || remaining="$remaining $other"
  done
  SELECTED_MODULES="${remaining# }"; export SELECTED_MODULES
  set_selected_modules "$SELECTED_MODULES"

  # Re-merge so the stack description no longer mentions the module. Data
  # volumes are untouched: re-enabling picks them straight back up.
  stage_modules
  merge_compose
  log_ok "Module '$id' disabled (data preserved). Remaining: $SELECTED_MODULES"
}

# --- health ----------------------------------------------------------------
cmd_health() { # id
  local id="$1"
  require_known_module "$id"
  local script
  script="$(manifest_field "$id" '(data.get("health") or {}).get("script","") if isinstance(data.get("health"), dict) else ""')"
  if [ -z "$script" ]; then
    log_ok "Module '$id' declares no health script; skipping."
    return 0
  fi
  local path="$SENTINEL_ETC/modules/$id/$script"
  [ -f "$path" ] || path="$INSTALLER_ROOT/modules/$id/$script"
  [ -f "$path" ] || die "Health script not found for '$id' ($script)." \
                        "Expected under $SENTINEL_ETC/modules/$id/ or $INSTALLER_ROOT/modules/$id/."
  bash "$path"
}

# --- status ----------------------------------------------------------------
cmd_status() {
  local current; current="$(selected_modules)"
  SELECTED_MODULES="$current"; export SELECTED_MODULES
  local id state gate six
  printf '%-10s %-9s %-14s %s\n' MODULE STATE GATE NOTES
  for id in $(manifest_ids); do
    module_selected "$id" && state=enabled || state=disabled
    gate="$(manifest_harness_family "$id")"
    six="$(manifest_disable_requires "$id")"
    printf '%-10s %-9s %-14s %s\n' "$id" "$state" "${gate:--}" \
      "$([ -n "$six" ] && echo 'Security Six - disabling needs a compensating control' || true)"
  done
}

# --- dispatch --------------------------------------------------------------
ACTION="${1:-}"; shift || true
MODULE="${1:-}"
case "$ACTION" in status|-h|--help|'') : ;; *) shift || true ;; esac

REASON=""; APPROVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason)   REASON="${2:-}"; shift 2 ;;
    --approver) APPROVER="${2:-}"; shift 2 ;;
    *) die "Unknown argument '$1'." "Run with --help for usage." ;;
  esac
done

case "$ACTION" in
  enable)  [ -n "$MODULE" ] || { usage; exit 1; }; cmd_enable  "$MODULE" ;;
  disable) [ -n "$MODULE" ] || { usage; exit 1; }; cmd_disable "$MODULE" "$REASON" "$APPROVER" ;;
  health)  [ -n "$MODULE" ] || { usage; exit 1; }; cmd_health  "$MODULE" ;;
  status)  cmd_status ;;
  -h|--help|'') usage ;;
  *) usage; exit 1 ;;
esac
