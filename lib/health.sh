#!/usr/bin/env bash
# lib/health.sh — per-step health gate for the §2.6 first-boot ordering.
# Every startup step loops on its health condition with a timeout; on failure
# it prints the step name plus remediation text and HALTS — the installer never
# leaves a half-built stack silently (plan §2.6 "Ordering on first boot").
# shellcheck shell=bash

# wait_healthy "Step name" timeout_seconds "remediation text" check_fn [args...]
# check_fn must return 0 when healthy.
wait_healthy() {
  local step="$1" timeout="$2" remediation="$3"; shift 3
  local start now
  start="$(date +%s)"
  log "Health gate: ${step} (timeout ${timeout}s)"
  while true; do
    if "$@" >/dev/null 2>&1; then
      log_ok "Step healthy: ${step}"
      return 0
    fi
    now="$(date +%s)"
    if [ $(( now - start )) -ge "$timeout" ]; then
      log_err "First-boot step FAILED its health gate: ${step}"
      die "Halting so you are not left with a half-built stack. Failed step: ${step}" \
          "${remediation}
After fixing the cause, re-run the installer — it is idempotent and resumes from the failed step.
Inspect logs with: docker compose -f ${SENTINEL_COMPOSE} --env-file ${SENTINEL_ENV_FILE} logs --tail 100"
    fi
    sleep 5
  done
}

# --- Reusable check functions -------------------------------------------------

compose_cmd() {
  docker compose -f "$SENTINEL_COMPOSE" --env-file "$SENTINEL_ENV_FILE" "$@"
}

# Container reports healthy (or running when it defines no healthcheck)
check_container_healthy() { # service-name
  local cid state health
  cid="$(compose_cmd ps -q "$1" 2>/dev/null | head -n1)"
  [ -n "$cid" ] || return 1
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" || return 1
  [ "$state" = "running" ] || return 1
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
  [ "$health" = "healthy" ] || [ "$health" = "none" ]
}

check_all_healthy() { # service... — all must pass check_container_healthy
  local s
  for s in "$@"; do check_container_healthy "$s" || return 1; done
  return 0
}

check_http_ok() { # url [insecure]
  local flags=(-fsS -o /dev/null --max-time 10)
  [ "${2:-}" = "insecure" ] && flags+=(-k)
  curl "${flags[@]}" "$1"
}

check_tcp_open() { # host port
  (exec 3<>"/dev/tcp/$1/$2") 2>/dev/null && exec 3>&- 3<&-
}

check_file_exists() { [ -s "$1" ]; }

check_pg_ready() { # service dbuser
  compose_cmd exec -T "$1" pg_isready -U "${2:-sentinel}" -q
}

check_redis_ready() { # service
  compose_cmd exec -T "$1" redis-cli ping | grep -q PONG
}
