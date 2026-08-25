#!/usr/bin/env bash
# lib/common.sh — shared helpers for the Vibe Sentinel installer.
# Sourced by install.sh, preflight/*, wizard, upgrade, uninstall.
# shellcheck shell=bash

set -o pipefail

# ---------------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------------
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
SENTINEL_CONFIG="${SENTINEL_CONFIG:-$SENTINEL_ETC/config.json}"
SENTINEL_ENV_FILE="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
SENTINEL_COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
SENTINEL_RISKS="${SENTINEL_RISKS:-$SENTINEL_ETC/preflight-risks.json}"
SENTINEL_LOG="${SENTINEL_LOG:-/var/log/vibe-sentinel-install.log}"

# Repo root = directory that contains lib/ (resolved from this file's location)
if [ -z "${INSTALLER_ROOT:-}" ]; then
  INSTALLER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
MANIFEST_FILE="${MANIFEST_FILE:-$INSTALLER_ROOT/versions/manifest.json}"

# All known modules, install order irrelevant here (ordering is in install.sh)
ALL_MODULES="core runtime edge mesh keys pulse print scan ai"
DEFAULT_MODULES="core runtime edge mesh keys pulse print ai"
SECURITY_SIX_MODULES="mesh keys pulse print"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_c_red=$'\033[0;31m'; _c_grn=$'\033[0;32m'; _c_yel=$'\033[0;33m'
_c_cyn=$'\033[0;36m'; _c_off=$'\033[0m'
[ -t 1 ] || { _c_red=""; _c_grn=""; _c_yel=""; _c_cyn=""; _c_off=""; }

_log_line() { # level message...
  local lvl="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$*" >>"$SENTINEL_LOG" 2>/dev/null || true
}

log()      { printf '%s[sentinel]%s %s\n' "$_c_cyn" "$_c_off" "$*"; _log_line INFO "$*"; }
log_ok()   { printf '%s[  OK  ]%s %s\n' "$_c_grn" "$_c_off" "$*"; _log_line OK "$*"; }
log_warn() { printf '%s[ WARN ]%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; _log_line WARN "$*"; }
log_err()  { printf '%s[ FAIL ]%s %s\n' "$_c_red" "$_c_off" "$*" >&2; _log_line FAIL "$*"; }

# Preflight result helpers — every check prints PASS/FAIL with a plain-English reason.
pf_pass() { printf '%sPASS%s  %s\n' "$_c_grn" "$_c_off" "$*"; _log_line PASS "$*"; return 0; }
pf_fail() { printf '%sFAIL%s  %s\n' "$_c_red" "$_c_off" "$*"; _log_line FAIL "$*"; return 1; }
pf_warn() { printf '%sWARN%s  %s\n' "$_c_yel" "$_c_off" "$*"; _log_line WARN "$*"; return 0; }

# die "message" ["remediation text"]
# Never leave a half-explained failure: always say what to do next, then halt.
die() {
  log_err "$1"
  if [ -n "${2:-}" ]; then
    printf '\n%sWhat to do:%s %s\n\n' "$_c_yel" "$_c_off" "$2" >&2
  fi
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This installer must run as root (it configures sysctl, firewall, Docker, and /etc/vibe-sentinel)." \
        "Re-run with: sudo bash $0 $ORIG_ARGS"
  fi
}

require_cmd() { # cmd apt-package
  command -v "$1" >/dev/null 2>&1 || \
    die "Required command '$1' is not installed." "Install it with: apt-get install -y ${2:-$1}"
}

# ---------------------------------------------------------------------------
# JSON helpers (jq required; preflight/os.sh enforces it early)
# ---------------------------------------------------------------------------
json_get() { # file jq-expression [default]
  local v
  v="$(jq -r "$2 // empty" "$1" 2>/dev/null)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${3:-}"; fi
}

config_get() { json_get "$SENTINEL_CONFIG" "$1" "${2:-}"; }

# Append a risk item to the preflight risk register (picked up by sentinel-api
# on first boot and turned into risk_assessment entries — see plan §2.6/Falco fallback).
record_risk() { # id title detail
  mkdir -p "$SENTINEL_ETC"
  [ -s "$SENTINEL_RISKS" ] || printf '{"risks":[]}\n' >"$SENTINEL_RISKS"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$1" --arg title "$2" --arg detail "$3" \
     --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.risks += [{id:$id, title:$title, detail:$detail, recorded_at:$at}]' \
     "$SENTINEL_RISKS" >"$tmp" && mv "$tmp" "$SENTINEL_RISKS"
  chmod 600 "$SENTINEL_RISKS"
  log_warn "Risk item recorded: $1 — $2"
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
version_ge() { # version_ge 24.0.7 24  → true if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
}

# ---------------------------------------------------------------------------
# Module helpers
# ---------------------------------------------------------------------------
module_selected() { # module-id  — reads SELECTED_MODULES (space separated)
  case " ${SELECTED_MODULES:-} " in *" $1 "*) return 0;; *) return 1;; esac
}

validate_module_list() { # comma-or-space separated list -> echoes normalized list or dies
  local raw m out=""
  raw="$(printf '%s' "$1" | tr ',' ' ')"
  for m in $raw; do
    case " $ALL_MODULES " in
      *" $m "*) out="$out $m" ;;
      *) die "Unknown module '$m'." "Valid modules: $ALL_MODULES" ;;
    esac
  done
  case " $out " in *" core "*) : ;; *) out="core $out" ;; esac  # core is required
  printf '%s' "${out# }"
}

random_secret() { # [bytes]
  openssl rand -hex "${1:-32}"
}
