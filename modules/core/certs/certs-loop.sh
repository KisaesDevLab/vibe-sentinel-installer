#!/bin/sh
# sentinel-certs sidecar: obtain and renew the *.<domain> wildcard via ACME
# DNS-01 through the Cloudflare API (lego), then distribute to the shared
# /certs volume consumed by Vaultwarden, Uptime Kuma, Vibe Print, Authentik,
# and the Sentinel UI (plan §2.6 "DNS and TLS plan" — no private CA anywhere).
#
# Renewal failure surfaces as SENT-U-003 / SENT-V-SENT-001 (cert-age monitor).
set -eu

DOMAIN="${SENTINEL_DOMAIN:?SENTINEL_DOMAIN required}"
EMAIL="${ACME_EMAIL:?ACME_EMAIL required}"
LEGO_PATH=/certs/lego
LIVE=/certs/live

mkdir -p "$LEGO_PATH" "$LIVE"

publish() {
  # lego names files after the first (escaped) domain
  crt="$LEGO_PATH/certificates/_.${DOMAIN}.crt"
  key="$LEGO_PATH/certificates/_.${DOMAIN}.key"
  if [ -s "$crt" ] && [ -s "$key" ]; then
    cp "$crt" "$LIVE/wildcard.crt.tmp" && mv "$LIVE/wildcard.crt.tmp" "$LIVE/wildcard.crt"
    cp "$key" "$LIVE/wildcard.key.tmp" && mv "$LIVE/wildcard.key.tmp" "$LIVE/wildcard.key"
    chmod 644 "$LIVE/wildcard.crt"
    chmod 640 "$LIVE/wildcard.key"
    echo "[certs] published wildcard cert for *.${DOMAIN} to $LIVE"
  fi
}

while true; do
  if [ ! -s "$LEGO_PATH/certificates/_.${DOMAIN}.crt" ]; then
    echo "[certs] obtaining wildcard certificate *.${DOMAIN} (ACME DNS-01 via Cloudflare)"
    lego --accept-tos --email "$EMAIL" --dns cloudflare \
         --domains "*.${DOMAIN}" --path "$LEGO_PATH" run || {
      echo "[certs] ACME issuance FAILED — retrying in 5 minutes" >&2
      sleep 300
      continue
    }
  else
    echo "[certs] renewal check for *.${DOMAIN}"
    lego --accept-tos --email "$EMAIL" --dns cloudflare \
         --domains "*.${DOMAIN}" --path "$LEGO_PATH" renew --days 30 || \
      echo "[certs] renewal attempt failed — will retry next cycle (SENT-U-003 fires at <14d)" >&2
  fi
  publish
  sleep 86400
done
