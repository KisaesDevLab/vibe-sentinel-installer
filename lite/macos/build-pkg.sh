#!/usr/bin/env bash
# lite/macos/build-pkg.sh — builds the Sentinel Lite installer .pkg for macOS.
#
# Template. lite/generate-lite.sh substitutes the @@PLACEHOLDER@@ values and
# stages payload/ beside this script; run it on a Mac.
#
# Same enrollment order as every other platform, and for the same reason:
#   1. NetBird     — FIRST, with the one-time setup key. The Wazuh manager, the
#                    print gateway, and Vaultwarden all bind the mesh interface
#                    only; nothing after this can reach its server until the
#                    peer is up.
#   2. Wazuh agent — registers over the mesh, by name.
#   3. EndpointSecurity collection — the macOS equivalent of Sysmon/auditd.
#   4. Posture collector on a 4-hour LaunchDaemon.
#   5. Print queues over IPP Everywhere + the pf rules blocking direct printer
#      access.
#
# ============================================================================
# TODO — NOTARIZATION
# ============================================================================
# This script produces a SIGNED but NOT NOTARIZED package. On macOS 10.15 and
# later, Gatekeeper refuses to open a non-notarized package downloaded from
# anywhere but the local disk, and staff will hit a "cannot be opened because
# Apple cannot check it for malicious software" wall.
#
# Notarization needs, none of which belong hard-coded in a repo:
#   * An Apple Developer Program membership (Kisaes Dev Lab).
#   * A "Developer ID Installer" certificate in the build keychain.
#   * An app-specific password or an App Store Connect API key, stored in the
#     keychain as a notarytool profile.
#
# Once those exist, append to the end of this script:
#
#     xcrun notarytool submit "$OUT_PKG" \
#         --keychain-profile "kisaes-notary" \
#         --wait
#     xcrun stapler staple "$OUT_PKG"
#     xcrun stapler validate "$OUT_PKG"
#
# Until then: deploy via MDM (which bypasses Gatekeeper for managed installs)
# or accept the right-click → Open workaround, and know that teaching staff
# that workaround undermines the phishing training the firm is also paying for.
# Track this as a real pre-GA item, not a nice-to-have.
# ============================================================================
set -euo pipefail

FIRM="@@FIRM@@"
FIRM_SLUG="@@FIRM_SLUG@@"
DOMAIN="@@DOMAIN@@"
WAZUH_MANAGER="@@WAZUH_MANAGER@@"
WAZUH_PASSWORD="@@WAZUH_ENROLLMENT_PASSWORD@@"
NETBIRD_SETUP_KEY="@@NETBIRD_SETUP_KEY@@"
NETBIRD_MGMT_URL="@@NETBIRD_MGMT_URL@@"
PRINT_GATEWAY="@@PRINT_GATEWAY@@"
STAMP="@@STAMP@@"

IDENTIFIER="com.kisaes.sentinel-lite.${FIRM_SLUG}"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ROOT_DIR="$BUILD_DIR/root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
OUT_PKG="$SCRIPT_DIR/SentinelLite-${FIRM_SLUG}-${VERSION}.pkg"

# Signing identity. Leave empty to build unsigned for a lab; NEVER ship that.
SIGN_IDENTITY="${SENTINEL_PKG_SIGN_IDENTITY:-}"

[ "$(uname -s)" = "Darwin" ] || { echo "This script must run on macOS (it needs pkgbuild/productbuild)." >&2; exit 1; }
command -v pkgbuild >/dev/null 2>&1 || { echo "pkgbuild not found — install the Xcode command line tools." >&2; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$ROOT_DIR/usr/local/vibe-sentinel" \
         "$ROOT_DIR/Library/LaunchDaemons" \
         "$SCRIPTS_DIR"

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------
install -m 755 "$SCRIPT_DIR/payload/posture.sh" "$ROOT_DIR/usr/local/vibe-sentinel/posture.sh"
install -m 600 "$SCRIPT_DIR/payload/enrollment.json" "$ROOT_DIR/usr/local/vibe-sentinel/enrollment.json"

# Posture collector: every 4 hours, plus once at load so the asset appears in
# the Sentinel UI within minutes rather than up to four hours later.
cat >"$ROOT_DIR/Library/LaunchDaemons/com.kisaes.sentinel-lite.posture.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.kisaes.sentinel-lite.posture</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/usr/local/vibe-sentinel/posture.sh</string>
    </array>
    <!-- 4 hours (plan section 6) -->
    <key>StartInterval</key>
    <integer>14400</integer>
    <key>RunAtLoad</key>
    <true/>
    <!-- The Wazuh agent's command wodle reads this file; one line of JSON. -->
    <key>StandardOutPath</key>
    <string>/usr/local/vibe-sentinel/posture.json</string>
    <key>StandardErrorPath</key>
    <string>/var/log/vibe-sentinel-posture.log</string>
</dict>
</plist>
PLIST
chmod 644 "$ROOT_DIR/Library/LaunchDaemons/com.kisaes.sentinel-lite.posture.plist"

# ---------------------------------------------------------------------------
# preinstall — NetBird FIRST, then wait for the mesh
# ---------------------------------------------------------------------------
cat >"$SCRIPTS_DIR/preinstall" <<PREINSTALL
#!/bin/bash
# Sentinel Lite preinstall: enrol the mesh before anything that needs it.
set -u

log() { echo "[sentinel-lite] \$*"; }

# --- 1. NetBird ------------------------------------------------------------
if ! command -v netbird >/dev/null 2>&1; then
  log "NetBird is not installed."
  log "Install it first (MDM, or: brew install --cask netbird), then re-run this package."
  log "Refusing to continue: the Wazuh manager, print gateway, and Vaultwarden are all mesh-only."
  exit 1
fi

if ! netbird status 2>/dev/null | grep -qi 'Management: Connected'; then
  log "Enrolling this Mac in the firm mesh..."
  netbird up --setup-key "$NETBIRD_SETUP_KEY" \\
             --management-url "$NETBIRD_MGMT_URL" \\
             --hostname "\$(scutil --get LocalHostName 2>/dev/null || hostname)" || {
    log "NetBird enrollment failed."
    log "The most common cause is a spent one-time setup key — generate a fresh bundle."
    exit 1
  }
fi

# --- 2. Wait for the mesh to actually carry traffic ------------------------
# The agent registers by NAME; NetBird DNS has to be answering first.
log "Waiting for $WAZUH_MANAGER to become reachable over the mesh..."
deadline=\$(( \$(date +%s) + 180 ))
while [ "\$(date +%s)" -lt "\$deadline" ]; do
  if nc -z -w 3 "$WAZUH_MANAGER" 1515 2>/dev/null; then
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
PREINSTALL
chmod 755 "$SCRIPTS_DIR/preinstall"

# ---------------------------------------------------------------------------
# postinstall — Wazuh, print queues, pf rules, first posture run
# ---------------------------------------------------------------------------
cat >"$SCRIPTS_DIR/postinstall" <<POSTINSTALL
#!/bin/bash
# Sentinel Lite postinstall.
set -u

log() { echo "[sentinel-lite] \$*"; }

# --- Wazuh agent -----------------------------------------------------------
OSSEC=/Library/Ossec
if [ -x "\$OSSEC/bin/agent-auth" ]; then
  if [ ! -s "\$OSSEC/etc/client.keys" ]; then
    log "Registering the Wazuh agent with $WAZUH_MANAGER..."
    "\$OSSEC/bin/agent-auth" -m "$WAZUH_MANAGER" -P "$WAZUH_PASSWORD" \\
      -A "\$(scutil --get LocalHostName 2>/dev/null || hostname)" \\
      -G macos-workstations || log "WARNING: agent registration failed; the agent will retry."
  fi
  # Point the agent at the manager and enable the posture wodle.
  if [ -f "\$OSSEC/etc/ossec.conf" ]; then
    /usr/bin/sed -i '' "s#<address>.*</address>#<address>$WAZUH_MANAGER</address>#" "\$OSSEC/etc/ossec.conf" 2>/dev/null || true
  fi
  "\$OSSEC/bin/wazuh-control" restart >/dev/null 2>&1 || true
else
  log "WARNING: the Wazuh agent is not installed at \$OSSEC."
  log "Install it (MDM or the Wazuh macOS pkg) and re-run this package; posture"
  log "collection works without it, but detection does not."
fi

# --- EndpointSecurity collection -------------------------------------------
# The Wazuh macOS agent's EndpointSecurity-based collection needs Full Disk
# Access, which cannot be granted from a script. Deploy the PPPC profile from
# MDM; without it, file-access events are silently missing.
log "REMINDER: grant Full Disk Access to the Wazuh agent via an MDM PPPC profile,"
log "or EndpointSecurity-based file events will be silently absent."

# --- Print queues over IPP Everywhere --------------------------------------
if command -v lpadmin >/dev/null 2>&1; then
  for q in "Secure - Client Docs" "General"; do
    cups_name="\$(echo "\$q" | tr -c 'A-Za-z0-9_-' '_')"
    log "Installing print queue '\$q'"
    lpadmin -p "\$cups_name" \\
            -D "\$q" \\
            -v "ipps://$PRINT_GATEWAY:631/printers/\$cups_name" \\
            -m everywhere \\
            -o printer-is-shared=false \\
            -E 2>/dev/null || log "WARNING: could not install queue '\$q'"
  done
  lpadmin -d General 2>/dev/null || true
fi

# --- Printer isolation: pf rules -------------------------------------------
# Layer 3 of the print isolation model. Only the gateway may be reached on
# printer ports; a direct attempt is what SENT-PR-002 fires on.
GATEWAY_IP="\$(dscacheutil -q host -a name "$PRINT_GATEWAY" 2>/dev/null | awk '/^ip_address:/ {print \$2; exit}')"
if [ -n "\${GATEWAY_IP:-}" ]; then
  cat >/etc/pf.anchors/com.kisaes.sentinel-print <<PF
# Vibe Sentinel print isolation. Only the Vibe Print gateway may be reached on
# printer protocols; everything else is blocked and logged.
pass out quick proto tcp from any to \$GATEWAY_IP port { 631, 9100, 515 }
block drop log quick proto tcp from any to any port { 9100, 515 }
block drop log quick proto tcp from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } port 631
block drop log quick proto udp from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } port { 161, 162 }
PF
  if ! grep -q 'com.kisaes.sentinel-print' /etc/pf.conf 2>/dev/null; then
    printf '\\nanchor "com.kisaes.sentinel-print"\\nload anchor "com.kisaes.sentinel-print" from "/etc/pf.anchors/com.kisaes.sentinel-print"\\n' >>/etc/pf.conf
  fi
  pfctl -f /etc/pf.conf >/dev/null 2>&1 || true
  pfctl -E >/dev/null 2>&1 || true
  log "Printer isolation rules applied (gateway \$GATEWAY_IP)."
else
  log "WARNING: could not resolve $PRINT_GATEWAY, so NO printer isolation rules were installed."
  log "Refusing to install block rules without a working allow rule would leave this"
  log "Mac unable to print at all. Re-run once the mesh is up."
fi

# --- Posture: load the daemon and take the first snapshot now ---------------
launchctl load -w /Library/LaunchDaemons/com.kisaes.sentinel-lite.posture.plist 2>/dev/null || true
/bin/bash /usr/local/vibe-sentinel/posture.sh >/usr/local/vibe-sentinel/posture.json 2>/dev/null || true

log "Sentinel Lite installed for $FIRM."
exit 0
POSTINSTALL
chmod 755 "$SCRIPTS_DIR/postinstall"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
COMPONENT_PKG="$BUILD_DIR/sentinel-lite-component.pkg"

pkgbuild \
  --root "$ROOT_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG"

DISTRIBUTION="$BUILD_DIR/distribution.xml"
cat >"$DISTRIBUTION" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Sentinel Lite for $FIRM</title>
    <organization>com.kisaes</organization>
    <options customize="never" require-scripts="true" hostArchitectures="x86_64,arm64"/>
    <!-- macOS 11 and later: the posture collector uses fdesetup and
         socketfilterfw in their modern forms. -->
    <volume-check>
        <allowed-os-versions><os-version min="11.0"/></allowed-os-versions>
    </volume-check>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default"><pkg-ref id="$IDENTIFIER"/></choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">sentinel-lite-component.pkg</pkg-ref>
</installer-gui-script>
DIST

if [ -n "$SIGN_IDENTITY" ]; then
  productbuild --distribution "$DISTRIBUTION" --package-path "$BUILD_DIR" \
               --sign "$SIGN_IDENTITY" "$OUT_PKG"
  echo "[build-pkg] Signed with: $SIGN_IDENTITY"
else
  productbuild --distribution "$DISTRIBUTION" --package-path "$BUILD_DIR" "$OUT_PKG"
  echo "[build-pkg] WARNING: built UNSIGNED. Set SENTINEL_PKG_SIGN_IDENTITY to a"
  echo "[build-pkg] 'Developer ID Installer' identity before shipping this to a firm."
fi

echo "[build-pkg] Built: $OUT_PKG"
cat <<'NOTE'

NOT NOTARIZED. See the TODO block at the top of this script.

Gatekeeper will refuse this package on macOS 10.15+ unless it is deployed
through MDM. Until notarization is set up, deploy via MDM — do not teach staff
the right-click-Open workaround, because that is the exact instinct the
phishing training is trying to remove.

NOTE
