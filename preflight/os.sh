#!/usr/bin/env bash
# preflight/os.sh — supported OS check (Ubuntu 22.04 / 24.04, Debian 12) and
# base tooling the installer itself needs.
# shellcheck shell=bash

preflight_os() {
  if [ ! -r /etc/os-release ]; then
    pf_fail "Cannot read /etc/os-release — this does not look like a supported Linux host."
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID}:${VERSION_ID}" in
    ubuntu:22.04|ubuntu:24.04|debian:12)
      pf_pass "Operating system supported: ${PRETTY_NAME}"
      ;;
    *)
      pf_fail "Unsupported operating system: ${PRETTY_NAME:-unknown}. Vibe Sentinel supports Ubuntu 22.04, Ubuntu 24.04, and Debian 12 only. Install one of those (a plain DigitalOcean droplet or stock server image is fine) and re-run."
      return 1
      ;;
  esac

  local missing=""
  local cmd
  for cmd in curl jq openssl ss ip; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
  done
  if [ -n "$missing" ]; then
    pf_fail "Missing required tools:${missing}. Install them with: apt-get update && apt-get install -y curl jq openssl iproute2"
    return 1
  fi
  pf_pass "Required tools present (curl, jq, openssl, ss, ip)"
  return 0
}
