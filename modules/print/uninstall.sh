#!/usr/bin/env bash
# modules/print/uninstall.sh — removes the Vibe Print services, the generated
# printer-isolation firewall rules, and (after the top-level uninstall.sh has
# offered a data export) the print volumes.
#
# The spool volume can contain rendered client documents awaiting release, so
# it is dropped only when REMOVE_VOLUMES=1 is set explicitly after the export
# prompt — and then with a secure delete pass, not a plain volume rm.
set -euo pipefail
SENTINEL_ETC="${SENTINEL_ETC:-/etc/vibe-sentinel}"
COMPOSE="${SENTINEL_COMPOSE:-$SENTINEL_ETC/compose.yml}"
ENVF="${SENTINEL_ENV_FILE:-$SENTINEL_ETC/.env}"
REMOVE_VOLUMES="${REMOVE_VOLUMES:-0}"

docker compose -f "$COMPOSE" --env-file "$ENVF" rm -sf \
  vibe-print vibe-print-release vibe-print-scanner-inbox || true

# Remove the printer-isolation nftables table this module created.
if command -v nft >/dev/null 2>&1; then
  nft delete table inet vibe_print 2>/dev/null || true
fi
rm -f /etc/nftables.d/vibe-print.nft \
      "$SENTINEL_ETC/modules/print/.printer-policy-applied" \
      "$SENTINEL_ETC/modules/print/netbird-printer-policy.json" 2>/dev/null || true

if [ "$REMOVE_VOLUMES" = "1" ]; then
  # Overwrite spooled job data before dropping the volume.
  for v in print-spool print-scanner-inbox; do
    docker run --rm -v "vibe-sentinel_${v}:/target" alpine:3 \
      sh -c 'find /target -type f -exec shred -u -n 1 {} + 2>/dev/null; rm -rf /target/* 2>/dev/null' \
      >/dev/null 2>&1 || true
  done
  for v in print-spool print-cups-config print-scanner-inbox; do
    docker volume rm -f "vibe-sentinel_${v}" 2>/dev/null || true
  done
fi

echo "print module removed (volumes removed: $REMOVE_VOLUMES)."
echo "Workstations still hold the firm print queues and the 9100/631/515 egress firewall rules from their Lite bundle."
echo "Remove those with lite/print-queue/firewall/uninstall, or workstations will have no working print path."
echo "REQ-063 paper-trail evidence stops accruing from this point."
