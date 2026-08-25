#!/usr/bin/env bash
# lite/linux/build-deb.sh — builds the Sentinel Lite .deb for Debian/Ubuntu
# workstations and servers.
#
# Template. lite/generate-lite.sh substitutes the @@PLACEHOLDER@@ values and
# stages payload/ beside this script, including the auditd rule files it picked
# for the requested --role.
#
# Same enrollment order as every other platform, and for the same reason:
#   1. NetBird     — FIRST, with the one-time setup key. Every Sentinel service
#                    binds the mesh interface only.
#   2. Wazuh agent — registers over the mesh, by name.
#   3. auditd      — the generic baseline on every host, plus the per-role
#                    overlay (docker-host / db-host). This is the Linux
#                    equivalent of Sysmon, and it is what the SENT-H-* and
#                    SENT-D-* packs read.
#   4. Posture collector on a 4-hour systemd timer.
#   5. Print queues over IPP Everywhere + nftables rules blocking direct
#      printer access.
#
# Build (on any Linux box with dpkg-deb; no root needed):
#   bash build-deb.sh
set -euo pipefail

FIRM="@@FIRM@@"
FIRM_SLUG="@@FIRM_SLUG@@"
DOMAIN="@@DOMAIN@@"
WAZUH_MANAGER="@@WAZUH_MANAGER@@"
WAZUH_PASSWORD="@@WAZUH_ENROLLMENT_PASSWORD@@"
NETBIRD_SETUP_KEY="@@NETBIRD_SETUP_KEY@@"
NETBIRD_MGMT_URL="@@NETBIRD_MGMT_URL@@"
PRINT_GATEWAY="@@PRINT_GATEWAY@@"
ROLE="@@ROLE@@"
STAMP="@@STAMP@@"

VERSION="1.0.0"
PKG_NAME="sentinel-lite-${FIRM_SLUG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build/$PKG_NAME"
OUT_DEB="$SCRIPT_DIR/${PKG_NAME}_${VERSION}_all.deb"

command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found — apt-get install -y dpkg-dev" >&2; exit 1; }

rm -rf "$SCRIPT_DIR/build"
mkdir -p "$BUILD_DIR/DEBIAN" \
         "$BUILD_DIR/usr/local/lib/vibe-sentinel" \
         "$BUILD_DIR/etc/audit/rules.d" \
         "$BUILD_DIR/etc/vibe-sentinel" \
         "$BUILD_DIR/lib/systemd/system"

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------
install -m 755 "$SCRIPT_DIR/payload/posture.sh" "$BUILD_DIR/usr/local/lib/vibe-sentinel/posture.sh"
install -m 600 "$SCRIPT_DIR/payload/enrollment.json" "$BUILD_DIR/etc/vibe-sentinel/enrollment.json"

# auditd rules — the baseline on every host, then the role overlay. The file
# NAMES matter: augenrules loads /etc/audit/rules.d/* in lexical order, so the
# 50- baseline is applied before the 60- role overlay can extend or override it.
AUDIT_INSTALLED=0
if [ -f "$SCRIPT_DIR/payload/auditd/50-sentinel-generic.rules" ]; then
  install -m 640 "$SCRIPT_DIR/payload/auditd/50-sentinel-generic.rules" \
                 "$BUILD_DIR/etc/audit/rules.d/50-sentinel-generic.rules"
  AUDIT_INSTALLED=1
  echo "[build-deb] auditd baseline: 50-sentinel-generic.rules"
fi
if [ -f "$SCRIPT_DIR/payload/auditd/60-sentinel-${ROLE}.rules" ]; then
  install -m 640 "$SCRIPT_DIR/payload/auditd/60-sentinel-${ROLE}.rules" \
                 "$BUILD_DIR/etc/audit/rules.d/60-sentinel-${ROLE}.rules"
  echo "[build-deb] auditd role overlay: 60-sentinel-${ROLE}.rules"
fi
if [ "$AUDIT_INSTALLED" -eq 0 ]; then
  echo "[build-deb] WARNING: no auditd rules staged. The host-integrity pack (SENT-H-*)" >&2
  echo "[build-deb] will be silent on machines installed from this package. Re-run" >&2
  echo "[build-deb] generate-lite.sh with MONOREPO_ROOT pointing at the Vibe-Sentinel checkout." >&2
fi

# ---------------------------------------------------------------------------
# Posture: systemd timer, every 4 hours plus once shortly after boot
# ---------------------------------------------------------------------------
cat >"$BUILD_DIR/lib/systemd/system/vibe-sentinel-posture.service" <<'UNIT'
[Unit]
Description=Vibe Sentinel Lite posture collection
Documentation=https://vibesentinel.app/docs/lite
After=network-online.target netbird.service
Wants=network-online.target

[Service]
Type=oneshot
# One line of JSON matching the PostureSnapshot interface. The Wazuh command
# wodle reads this file; anything else on stdout breaks ingestion.
ExecStart=/bin/bash -c '/usr/local/lib/vibe-sentinel/posture.sh > /var/lib/vibe-sentinel/posture.json'
User=root
# Reads system state only; no writes outside its own directory.
ProtectHome=yes
PrivateTmp=yes
NoNewPrivileges=yes
UNIT

cat >"$BUILD_DIR/lib/systemd/system/vibe-sentinel-posture.timer" <<'UNIT'
[Unit]
Description=Vibe Sentinel Lite posture collection (every 4 hours)

[Timer]
# Plan section 6: every 4 hours.
OnUnitActiveSec=4h
# A machine that was off during its window reports 2 minutes after it comes
# back, rather than waiting up to four hours.
OnBootSec=2min
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
UNIT

# ---------------------------------------------------------------------------
# Control file
# ---------------------------------------------------------------------------
cat >"$BUILD_DIR/DEBIAN/control" <<CONTROL
Package: $PKG_NAME
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Maintainer: Kisaes Dev Lab <security@$DOMAIN>
Depends: bash, coreutils, curl, auditd, cups-client
Recommends: nftables, netbird, wazuh-agent
Description: Sentinel Lite endpoint agent for $FIRM
 Enrolls this host into the firm's Vibe Sentinel deployment: mesh membership,
 Wazuh agent registration, auditd rule pack ($ROLE role), a 4-hour posture
 collector, the firm print queues over IPP Everywhere, and host firewall rules
 that block direct printer access.
 .
 Collects security telemetry, not content: no keystrokes, no screenshots, no
 file contents.
 .
 Generated $STAMP for $DOMAIN.
CONTROL

cat >"$BUILD_DIR/DEBIAN/conffiles" <<'CONFF'
/etc/vibe-sentinel/enrollment.json
CONFF

# ---------------------------------------------------------------------------
# preinst — NetBird FIRST, then wait for the mesh
# ---------------------------------------------------------------------------
cat >"$BUILD_DIR/DEBIAN/preinst" <<PREINST
#!/bin/bash
# Sentinel Lite preinst: enrol the mesh before anything that needs it.
set -u
[ "\$1" = "install" ] || [ "\$1" = "upgrade" ] || exit 0

log() { echo "[sentinel-lite] \$*"; }

if ! command -v netbird >/dev/null 2>&1; then
  log "NetBird is not installed."
  log "Install it first, then re-run this package:"
  log "  curl -fsSL https://pkgs.netbird.io/install.sh | sh"
  log "Refusing to continue: the Wazuh manager, print gateway, and Vaultwarden"
  log "are all mesh-only, so nothing in this package can reach its server yet."
  exit 1
fi

if ! netbird status 2>/dev/null | grep -qi 'Management: Connected'; then
  log "Enrolling this host in the firm mesh..."
  netbird up --setup-key "$NETBIRD_SETUP_KEY" \\
             --management-url "$NETBIRD_MGMT_URL" \\
             --hostname "\$(hostname -s)" || {
    log "NetBird enrollment failed."
    log "The most common cause is a spent one-time setup key — generate a fresh bundle."
    exit 1
  }
fi

log "Waiting for $WAZUH_MANAGER to become reachable over the mesh..."
deadline=\$(( \$(date +%s) + 180 ))
while [ "\$(date +%s)" -lt "\$deadline" ]; do
  if timeout 3 bash -c ": >/dev/tcp/$WAZUH_MANAGER/1515" 2>/dev/null; then
    log "Mesh is up; manager reachable."
    exit 0
  fi
  sleep 5
done

log "Timed out waiting for $WAZUH_MANAGER:1515."
log "Check: is this peer in the 'workstations' group in the NetBird admin UI?"
log "Is the Sentinel host itself enrolled? Its agent ports bind the mesh interface only."
log "Stopping here on purpose — an agent that cannot reach its manager looks"
log "enrolled and reports nothing, which is worse than a failed install."
exit 1
PREINST
chmod 755 "$BUILD_DIR/DEBIAN/preinst"

# ---------------------------------------------------------------------------
# postinst — Wazuh, auditd, posture timer, print queues, nftables
# ---------------------------------------------------------------------------
cat >"$BUILD_DIR/DEBIAN/postinst" <<POSTINST
#!/bin/bash
set -u
[ "\$1" = "configure" ] || exit 0

log() { echo "[sentinel-lite] \$*"; }
mkdir -p /var/lib/vibe-sentinel
chmod 750 /var/lib/vibe-sentinel

# --- Wazuh agent -----------------------------------------------------------
if [ -x /var/ossec/bin/agent-auth ]; then
  if [ ! -s /var/ossec/etc/client.keys ]; then
    log "Registering the Wazuh agent with $WAZUH_MANAGER..."
    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -P "$WAZUH_PASSWORD" \\
      -A "\$(hostname -s)" -G linux-$ROLE \\
      || log "WARNING: agent registration failed; the agent will retry."
  fi
  if [ -f /var/ossec/etc/ossec.conf ]; then
    sed -i "s#<address>.*</address>#<address>$WAZUH_MANAGER</address>#" /var/ossec/etc/ossec.conf 2>/dev/null || true
  fi
  systemctl restart wazuh-agent >/dev/null 2>&1 || /var/ossec/bin/wazuh-control restart >/dev/null 2>&1 || true
else
  log "WARNING: the Wazuh agent is not installed at /var/ossec."
  log "Install it and re-run 'dpkg-reconfigure $PKG_NAME'. Posture collection works"
  log "without it, but detection does not."
fi

# --- auditd ----------------------------------------------------------------
# Load the rules now rather than at next boot: a host that reboots weekly would
# otherwise run a week with no audit coverage.
if command -v augenrules >/dev/null 2>&1; then
  augenrules --load >/dev/null 2>&1 && log "auditd rules loaded ($ROLE role)." \\
    || log "WARNING: augenrules --load failed. Check for a conflicting audit consumer (auditd preflight covers this on the Sentinel host)."
  systemctl restart auditd >/dev/null 2>&1 || service auditd restart >/dev/null 2>&1 || true
else
  log "WARNING: augenrules not found; auditd rules are staged but not loaded."
fi

# --- Posture timer ---------------------------------------------------------
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable --now vibe-sentinel-posture.timer >/dev/null 2>&1 || true
# First snapshot immediately, so the asset appears with full posture in minutes.
systemctl start vibe-sentinel-posture.service >/dev/null 2>&1 || true

# --- Print queues over IPP Everywhere --------------------------------------
if command -v lpadmin >/dev/null 2>&1; then
  for q in "Secure - Client Docs" "General"; do
    cups_name="\$(echo "\$q" | tr -c 'A-Za-z0-9_-' '_')"
    log "Installing print queue '\$q'"
    lpadmin -p "\$cups_name" -D "\$q" \\
            -v "ipps://$PRINT_GATEWAY:631/printers/\$cups_name" \\
            -m everywhere -o printer-is-shared=false -E 2>/dev/null \\
      || log "WARNING: could not install queue '\$q'"
  done
  lpadmin -d General 2>/dev/null || true
fi

# --- Printer isolation: nftables -------------------------------------------
# Layer 3 of the print isolation model. Only the gateway may be reached on
# printer ports; a direct attempt is logged and is what SENT-PR-002 fires on.
GATEWAY_IP="\$(getent hosts "$PRINT_GATEWAY" 2>/dev/null | awk '{print \$1; exit}')"
if [ -n "\${GATEWAY_IP:-}" ] && command -v nft >/dev/null 2>&1; then
  mkdir -p /etc/nftables.d
  cat >/etc/nftables.d/vibe-sentinel-print.nft <<NFT
# Vibe Sentinel print isolation (endpoint side).
# Only the Vibe Print gateway may be reached on printer protocols.
table inet vibe_sentinel_print {
  chain output {
    type filter hook output priority 0; policy accept;
    ip daddr \$GATEWAY_IP tcp dport { 631, 9100, 515 } accept
    tcp dport { 9100, 515 } log prefix "sentinel-print-deny " counter drop
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 631 \\
      log prefix "sentinel-print-deny " counter drop
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } udp dport { 161, 162 } \\
      log prefix "sentinel-print-deny " counter drop
  }
}
NFT
  nft delete table inet vibe_sentinel_print 2>/dev/null || true
  nft -f /etc/nftables.d/vibe-sentinel-print.nft 2>/dev/null \\
    && log "Printer isolation rules applied (gateway \$GATEWAY_IP)." \\
    || log "WARNING: nftables rejected the printer isolation rules."
  if [ -f /etc/nftables.conf ] && ! grep -q 'nftables.d' /etc/nftables.conf; then
    printf '\\ninclude "/etc/nftables.d/*.nft"\\n' >>/etc/nftables.conf
  fi
  systemctl enable nftables >/dev/null 2>&1 || true
else
  log "WARNING: could not resolve $PRINT_GATEWAY (or nftables is missing), so NO"
  log "printer isolation rules were installed. Installing block rules without a"
  log "working allow rule would leave this host unable to print at all."
fi

log "Sentinel Lite installed for $FIRM."
exit 0
POSTINST
chmod 755 "$BUILD_DIR/DEBIAN/postinst"

# ---------------------------------------------------------------------------
# prerm — leave the agents alone; remove only what this package added
# ---------------------------------------------------------------------------
cat >"$BUILD_DIR/DEBIAN/prerm" <<'PRERM'
#!/bin/bash
set -u
[ "$1" = "remove" ] || [ "$1" = "upgrade" ] || exit 0

echo "[sentinel-lite] Removing the posture timer and printer isolation rules."
systemctl disable --now vibe-sentinel-posture.timer >/dev/null 2>&1 || true
nft delete table inet vibe_sentinel_print 2>/dev/null || true
rm -f /etc/nftables.d/vibe-sentinel-print.nft

# The Wazuh agent, NetBird, and the auditd service are deliberately LEFT
# INSTALLED. Pulling a host out of monitoring should never be a side effect of
# removing something else, and agent removal raises a tamper alert by design.
echo "[sentinel-lite] The Wazuh agent and NetBird are left installed on purpose."
echo "[sentinel-lite] Remove them deliberately if that is what you meant to do."
exit 0
PRERM
chmod 755 "$BUILD_DIR/DEBIAN/prerm"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
find "$BUILD_DIR" -type d -exec chmod 755 {} +
dpkg-deb --root-owner-group --build "$BUILD_DIR" "$OUT_DEB"

echo "[build-deb] Built: $OUT_DEB"
cat <<NOTE

Install with:
  sudo apt-get install -y ./$(basename "$OUT_DEB")

(apt, not dpkg -i — the package Depends on auditd and cups-client, and apt
resolves them. dpkg -i leaves a half-configured package if they are missing.)

HANDLING: this .deb contains a NetBird setup key and the Wazuh enrollment
password. Treat it like a password — move it over the mesh or on encrypted
media, never by email, and delete it when the batch is enrolled.

An RPM equivalent for RHEL/Fedora hosts is not built here yet; the same payload
and scriptlets port directly.

NOTE
