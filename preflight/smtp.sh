#!/usr/bin/env bash
# preflight/smtp.sh — sends a real test message through the firm's SMTP relay
# via curl smtp:// (plan §2.6: Vaultwarden invites, Authentik enrollment, and
# email alerts all depend on it, so it is verified before anything is pulled).
# shellcheck shell=bash

preflight_smtp() {
  local host port user pass from rcpt
  host="$(config_get '.smtp.host')"
  port="$(config_get '.smtp.port' '587')"
  user="$(config_get '.smtp.username')"
  pass="$(config_get '.smtp.password')"
  from="$(config_get '.smtp.from')"
  rcpt="$(config_get '.firm.qi_email')"

  if [ -z "$host" ] || [ -z "$rcpt" ]; then
    pf_fail "SMTP host or QI email missing from the wizard answers — cannot send the test message."
    return 1
  fi
  [ -n "$from" ] || from="$user"

  local msg
  msg="$(mktemp)"
  {
    printf 'From: Vibe Sentinel Installer <%s>\r\n' "$from"
    printf 'To: %s\r\n' "$rcpt"
    printf 'Subject: Vibe Sentinel SMTP preflight test\r\n'
    printf 'Date: %s\r\n' "$(date -R)"
    printf '\r\n'
    printf 'This is the Vibe Sentinel installer verifying the SMTP relay before install.\r\n'
    printf 'If you received this, alert email, Vaultwarden invites, and Authentik enrollment mail will work.\r\n'
  } >"$msg"

  local -a args=(-sS --max-time 30 --mail-from "$from" --mail-rcpt "$rcpt" --upload-file "$msg")
  [ -n "$user" ] && args+=(--user "$user:$pass")
  local url
  if [ "$port" = "465" ]; then
    url="smtps://$host:$port"
  else
    url="smtp://$host:$port"
    args+=(--ssl-reqd)   # require STARTTLS — credentials never cross plaintext
  fi

  if curl "${args[@]}" "$url" >/dev/null 2>&1; then
    rm -f "$msg"
    pf_pass "SMTP relay $host:$port accepted a test message to $rcpt (check the inbox to be sure it was delivered, not just accepted)."
    return 0
  fi
  rm -f "$msg"
  pf_fail "Could not send a test message through $host:$port. Check host, port (587 STARTTLS / 465 TLS), username, and password. Vaultwarden invites and alert email will not work until this passes."
  return 1
}
