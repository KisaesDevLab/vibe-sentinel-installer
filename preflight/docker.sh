#!/usr/bin/env bash
# preflight/docker.sh — Docker ≥ 24, Compose v2, and user namespaces NOT
# remapped (Falco and Wazuh need host PID visibility — plan §2.6).
# shellcheck shell=bash

preflight_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    pf_fail "Docker is not installed. Install Docker Engine 24 or newer: https://docs.docker.com/engine/install/ (apt repository method), then re-run."
    return 1
  fi

  local ver
  ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if [ -z "$ver" ]; then
    pf_fail "Docker is installed but the daemon is not reachable. Start it with: systemctl enable --now docker"
    return 1
  fi
  if ! version_ge "$ver" "24"; then
    pf_fail "Docker Engine $ver is too old — Vibe Sentinel needs 24 or newer. Upgrade via the Docker apt repository."
    return 1
  fi
  pf_pass "Docker Engine $ver (>= 24)"

  local cver
  cver="$(docker compose version --short 2>/dev/null)"
  if [ -z "$cver" ]; then
    pf_fail "Docker Compose v2 plugin is missing. Install it with: apt-get install -y docker-compose-plugin"
    return 1
  fi
  case "$cver" in
    1.*) pf_fail "Docker Compose $cver is the legacy v1 — install the v2 plugin: apt-get install -y docker-compose-plugin"; return 1 ;;
  esac
  pf_pass "Docker Compose v2 present ($cver)"

  # User namespace remapping breaks host-PID visibility for Falco/Wazuh.
  if docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'userns'; then
    pf_fail "Docker user namespace remapping is enabled (userns-remap). Falco and the Wazuh agent need real host PID visibility. Remove \"userns-remap\" from /etc/docker/daemon.json and restart Docker."
    return 1
  fi
  if [ -f /etc/docker/daemon.json ] && jq -e '."userns-remap" // empty' /etc/docker/daemon.json >/dev/null 2>&1; then
    pf_fail "\"userns-remap\" is set in /etc/docker/daemon.json. Remove it and restart Docker — Falco and Wazuh need host PID visibility."
    return 1
  fi
  pf_pass "Docker user namespaces not remapped"
  return 0
}
