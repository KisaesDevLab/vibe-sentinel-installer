#!/usr/bin/env bash
# lite/posture/posture.sh — Sentinel Lite posture collector for Linux and macOS.
#
# Emits EXACTLY ONE LINE of JSON on stdout matching the PostureSnapshot
# interface in packages/shared/src/types.ts. Nothing else goes to stdout — the
# Wazuh wodle that runs this every 4 hours parses the line as-is, and any stray
# output breaks ingestion into asset_posture. Diagnostics go to stderr.
#
# Field contract (do not add, rename, or drop any of these):
#   hostname              string
#   collectedAt           string  (ISO 8601, UTC)
#   diskEncrypted         bool|null
#   avPresent             bool|null
#   avDefinitionsAgeDays  number|null
#   firewallOn            bool|null
#   osPatchAgeDays        number|null
#   screenLockTimeoutMin  number|null
#   localAdmins           string[]
#   cloudSyncClients      string[]
#   pendingReboot         bool|null
#   mfaEnforced           bool|null
#
# null means "could not determine", which is NOT the same as false. A host
# where LUKS could not be queried must not be scored as unencrypted — the
# Security Six scorecard shows it as unknown and asks a human.
#
# PRIVACY: security telemetry, not content. No keystrokes, no screenshots, no
# file contents. See the staff privacy notice.
#
# Deliberately depends on nothing but coreutils and the platform's own tools —
# no jq, no python — because it runs on whatever the firm already has.
#
# Never exits non-zero on a probe failure: one failing check yields null for
# that field rather than losing the whole snapshot.

set -u

OS="$(uname -s)"
NOW_EPOCH="$(date -u +%s)"

# ---------------------------------------------------------------------------
# JSON helpers (no jq on endpoints)
# ---------------------------------------------------------------------------
json_escape() { # string -> escaped, no surrounding quotes
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
    | tr -d '\n\r'
}

json_str() { printf '"%s"' "$(json_escape "$1")"; }

json_bool() { # "" -> null, 0 -> false, 1 -> true
  case "${1:-}" in
    1) printf 'true' ;;
    0) printf 'false' ;;
    *) printf 'null' ;;
  esac
}

json_num() { # "" -> null, otherwise integer
  case "${1:-}" in
    ''|*[!0-9-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

json_array_from_lines() { # reads stdin, one element per line
  local first=1 line
  printf '['
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$first" -eq 1 ] || printf ','
    first=0
    json_str "$line"
  done
  printf ']'
}

days_since_epoch() { # epoch-seconds -> whole days
  local then="$1"
  [ -n "$then" ] || return 1
  case "$then" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( (NOW_EPOCH - then) / 86400 ))
}

file_mtime_epoch() { # path
  [ -e "$1" ] || return 1
  if [ "$OS" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# hostname / collectedAt
# ---------------------------------------------------------------------------
HOSTNAME_VAL="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown')"
COLLECTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------------------------------------------------------------------------
# diskEncrypted — LUKS (Linux) / FileVault (macOS)
# ---------------------------------------------------------------------------
DISK_ENCRYPTED=""
if [ "$OS" = "Darwin" ]; then
  if have fdesetup; then
    if fdesetup status 2>/dev/null | grep -qi 'FileVault is On'; then
      DISK_ENCRYPTED=1
    elif fdesetup status 2>/dev/null | grep -qi 'FileVault is Off'; then
      DISK_ENCRYPTED=0
    fi
  fi
  # Apple Silicon and T2 Macs encrypt at rest regardless; FileVault is still the
  # control that matters, because without it the key is available at boot.
else
  # Only the filesystem holding / counts. An encrypted data disk under a
  # clear-text root is not an encrypted machine.
  if have lsblk; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [ -n "$root_src" ]; then
      # Walk up the device tree looking for a crypt layer.
      if lsblk -no TYPE,NAME --inverse "$root_src" 2>/dev/null | awk '{print $1}' | grep -q '^crypt$'; then
        DISK_ENCRYPTED=1
      elif lsblk -no TYPE 2>/dev/null | grep -q '^crypt$'; then
        # A crypt layer exists somewhere but not under / — report unencrypted
        # root rather than crediting the machine for the wrong disk.
        DISK_ENCRYPTED=0
      else
        DISK_ENCRYPTED=0
      fi
    fi
  fi
  # cryptsetup confirms, and catches layouts lsblk reports oddly.
  if [ "$DISK_ENCRYPTED" = "0" ] && have cryptsetup; then
    if cryptsetup status "$(basename "$(findmnt -no SOURCE / 2>/dev/null)")" >/dev/null 2>&1; then
      DISK_ENCRYPTED=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# avPresent / avDefinitionsAgeDays
# ---------------------------------------------------------------------------
AV_PRESENT=""
AV_DEF_AGE=""

# Microsoft Defender for Endpoint — the common managed case on both platforms.
if have mdatp; then
  AV_PRESENT=0
  if mdatp health --field real_time_protection_enabled 2>/dev/null | grep -qi true; then
    AV_PRESENT=1
  fi
  def_age="$(mdatp health --field definitions_status 2>/dev/null | tr -d '"' | tr '[:upper:]' '[:lower:]')"
  case "$def_age" in
    up_to_date) AV_DEF_AGE=0 ;;
    *)
      # Fall back to the definitions timestamp when the status is not clean.
      def_updated="$(mdatp health --field definitions_updated 2>/dev/null | tr -d '"')"
      if [ -n "$def_updated" ]; then
        if [ "$OS" = "Darwin" ]; then
          e="$(date -j -f '%b %d, %Y at %I:%M:%S %p' "$def_updated" +%s 2>/dev/null || true)"
        else
          e="$(date -d "$def_updated" +%s 2>/dev/null || true)"
        fi
        [ -n "$e" ] && AV_DEF_AGE="$(days_since_epoch "$e" || true)"
      fi
      ;;
  esac
fi

# ClamAV — the usual answer on Linux servers and on staff Linux desktops.
if [ -z "$AV_PRESENT" ] || [ "$AV_PRESENT" = "0" ]; then
  if have clamdscan || have clamscan || [ -d /var/lib/clamav ]; then
    clam_running=0
    if have systemctl; then
      systemctl is-active --quiet clamav-daemon 2>/dev/null && clam_running=1
      systemctl is-active --quiet clamd 2>/dev/null && clam_running=1
      systemctl is-active --quiet clamd@scan 2>/dev/null && clam_running=1
    elif pgrep -x clamd >/dev/null 2>&1; then
      clam_running=1
    fi
    # Present means running. An installed-but-stopped scanner is not antivirus.
    [ "$clam_running" = "1" ] && AV_PRESENT=1
    [ -z "$AV_PRESENT" ] && AV_PRESENT=0

    # Definition age from the newest signature database file.
    newest=""
    for db in /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld \
              /var/lib/clamav/main.cvd /var/lib/clamav/main.cld; do
      m="$(file_mtime_epoch "$db" || true)"
      [ -n "$m" ] || continue
      if [ -z "$newest" ] || [ "$m" -gt "$newest" ]; then newest="$m"; fi
    done
    [ -n "$newest" ] && AV_DEF_AGE="$(days_since_epoch "$newest" || true)"
  fi
fi

# macOS built-in XProtect, as the floor. It is not a full AV, so it does not
# set avPresent on its own; it only supplies a definitions age when nothing
# better is installed, so a Mac with no third-party AV still reports honestly.
if [ "$OS" = "Darwin" ] && [ -z "$AV_DEF_AGE" ]; then
  for xp in /Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist \
            /System/Library/CoreServices/XProtect.bundle/Contents/Info.plist; do
    m="$(file_mtime_epoch "$xp" || true)"
    [ -n "$m" ] && { AV_DEF_AGE="$(days_since_epoch "$m" || true)"; break; }
  done
fi

# Other Linux endpoint agents worth recognising as "AV present".
if [ -z "$AV_PRESENT" ] || [ "$AV_PRESENT" = "0" ]; then
  for svc in sophos-spl falcon-sensor sentinelone crowdstrike-falcon-sensor \
             cbagentd eset_rtp; do
    if pgrep -f "$svc" >/dev/null 2>&1; then AV_PRESENT=1; break; fi
  done
fi

# ---------------------------------------------------------------------------
# firewallOn
# ---------------------------------------------------------------------------
FIREWALL_ON=""
if [ "$OS" = "Darwin" ]; then
  ALF=/usr/libexec/ApplicationFirewall/socketfilterfw
  if [ -x "$ALF" ]; then
    if "$ALF" --getglobalstate 2>/dev/null | grep -qi 'enabled'; then
      FIREWALL_ON=1
    else
      FIREWALL_ON=0
    fi
  elif have defaults; then
    st="$(defaults read /Library/Preferences/com.apple.alf globalstate 2>/dev/null || true)"
    case "$st" in 1|2) FIREWALL_ON=1 ;; 0) FIREWALL_ON=0 ;; esac
  fi
  # pf is the packet filter underneath; a firm may use it instead of the
  # application firewall, so an enabled pf also counts.
  if [ "${FIREWALL_ON:-0}" = "0" ] && have pfctl; then
    pfctl -s info 2>/dev/null | grep -qi 'Status: Enabled' && FIREWALL_ON=1
  fi
else
  if have ufw && ufw status 2>/dev/null | head -1 | grep -qi 'Status: active'; then
    FIREWALL_ON=1
  elif have firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qi running; then
    FIREWALL_ON=1
  elif have nft && [ -n "$(nft list ruleset 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)" ]; then
    # A ruleset exists. Only count it if something actually filters — an empty
    # table set is not a firewall.
    if nft list ruleset 2>/dev/null | grep -Eq 'policy (drop|reject)|(^|[[:space:]])(drop|reject)([[:space:]]|$)'; then
      FIREWALL_ON=1
    else
      FIREWALL_ON=0
    fi
  elif have iptables; then
    if iptables -S 2>/dev/null | grep -Eq '^-P (INPUT|FORWARD) (DROP|REJECT)' \
       || iptables -S 2>/dev/null | grep -Eq '^-A .*-j (DROP|REJECT)'; then
      FIREWALL_ON=1
    else
      FIREWALL_ON=0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# osPatchAgeDays — days since the last package/OS update actually applied
# ---------------------------------------------------------------------------
OS_PATCH_AGE=""
if [ "$OS" = "Darwin" ]; then
  # InstallHistory records every Apple update; take the newest.
  HIST=/Library/Receipts/InstallHistory.plist
  if [ -r "$HIST" ] && have plutil; then
    last="$(plutil -convert xml1 -o - "$HIST" 2>/dev/null \
            | grep -A1 '<key>date</key>' | grep '<date>' \
            | sed -e 's/.*<date>//' -e 's/<\/date>.*//' | sort | tail -1)"
    if [ -n "$last" ]; then
      e="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$last" +%s 2>/dev/null || true)"
      [ -n "$e" ] && OS_PATCH_AGE="$(days_since_epoch "$e" || true)"
    fi
  fi
  if [ -z "$OS_PATCH_AGE" ]; then
    m="$(file_mtime_epoch /var/db/softwareupdate/journal.plist || true)"
    [ -n "$m" ] && OS_PATCH_AGE="$(days_since_epoch "$m" || true)"
  fi
else
  # Debian/Ubuntu: the newest "Start-Date" in apt history.
  if [ -r /var/log/apt/history.log ]; then
    last="$(grep -h '^Start-Date:' /var/log/apt/history.log 2>/dev/null | tail -1 | sed 's/^Start-Date:[[:space:]]*//')"
    if [ -n "$last" ]; then
      e="$(date -d "$last" +%s 2>/dev/null || true)"
      [ -n "$e" ] && OS_PATCH_AGE="$(days_since_epoch "$e" || true)"
    fi
  fi
  # Rotated history, when the current log has been cleared.
  if [ -z "$OS_PATCH_AGE" ] && [ -r /var/log/apt/history.log.1.gz ] && have zgrep; then
    last="$(zgrep -h '^Start-Date:' /var/log/apt/history.log.1.gz 2>/dev/null | tail -1 | sed 's/^Start-Date:[[:space:]]*//')"
    if [ -n "$last" ]; then
      e="$(date -d "$last" +%s 2>/dev/null || true)"
      [ -n "$e" ] && OS_PATCH_AGE="$(days_since_epoch "$e" || true)"
    fi
  fi
  # RPM: the newest install/update time across the database.
  if [ -z "$OS_PATCH_AGE" ] && have rpm; then
    e="$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -1)"
    [ -n "$e" ] && OS_PATCH_AGE="$(days_since_epoch "$e" || true)"
  fi
  # Last resort: dpkg status mtime.
  if [ -z "$OS_PATCH_AGE" ]; then
    m="$(file_mtime_epoch /var/lib/dpkg/status || true)"
    [ -n "$m" ] && OS_PATCH_AGE="$(days_since_epoch "$m" || true)"
  fi
fi

# ---------------------------------------------------------------------------
# screenLockTimeoutMin
#
# The effective LOCK timeout. A screensaver or display blank that does not
# require a password is not a screen lock, and reporting its timeout would
# credit the machine for a control it does not have — so that case is null.
# ---------------------------------------------------------------------------
SCREEN_LOCK_MIN=""
if [ "$OS" = "Darwin" ]; then
  ask=""
  delay=""
  # Read the console user's settings, not root's.
  console_user="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [ -n "$console_user" ] && [ "$console_user" != "root" ] && have sudo; then
    ask="$(sudo -u "$console_user" defaults read com.apple.screensaver askForPassword 2>/dev/null || true)"
    delay="$(sudo -u "$console_user" defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || true)"
    idle="$(sudo -u "$console_user" defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || true)"
  else
    ask="$(defaults read com.apple.screensaver askForPassword 2>/dev/null || true)"
    delay="$(defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null || true)"
    idle="$(defaults -currentHost read com.apple.screensaver idleTime 2>/dev/null || true)"
  fi
  if [ "$ask" = "1" ]; then
    # Effective lock = screensaver idle time + grace delay.
    idle="${idle:-0}"; delay="${delay:-0}"
    idle="${idle%%.*}"; delay="${delay%%.*}"
    case "$idle$delay" in
      *[!0-9]*) : ;;
      *) SCREEN_LOCK_MIN=$(( (idle + delay) / 60 )) ;;
    esac
  fi
else
  # GNOME: idle-delay is the blank timeout; lock-enabled + lock-delay gate it.
  if have gsettings; then
    gsettings_user="$(who 2>/dev/null | awk '/:0|tty|seat/ {print $1; exit}')"
    run_gs() {
      if [ -n "${gsettings_user:-}" ] && [ "$(id -un)" != "$gsettings_user" ] && have sudo; then
        sudo -u "$gsettings_user" DISPLAY=:0 gsettings get "$@" 2>/dev/null
      else
        gsettings get "$@" 2>/dev/null
      fi
    }
    lock_enabled="$(run_gs org.gnome.desktop.screensaver lock-enabled || true)"
    if [ "$lock_enabled" = "true" ]; then
      idle="$(run_gs org.gnome.desktop.session idle-delay | sed 's/[^0-9]//g' || true)"
      lock_delay="$(run_gs org.gnome.desktop.screensaver lock-delay | sed 's/[^0-9]//g' || true)"
      idle="${idle:-0}"; lock_delay="${lock_delay:-0}"
      if [ "$idle" != "0" ]; then
        SCREEN_LOCK_MIN=$(( (idle + lock_delay) / 60 ))
      fi
    fi
  fi
  # KDE Plasma.
  if [ -z "$SCREEN_LOCK_MIN" ]; then
    for cfg in /home/*/.config/kscreenlockerrc; do
      [ -r "$cfg" ] || continue
      if grep -q '^Autolock=false' "$cfg" 2>/dev/null; then continue; fi
      t="$(grep -m1 '^Timeout=' "$cfg" 2>/dev/null | cut -d= -f2)"
      case "${t:-}" in
        ''|*[!0-9]*) : ;;
        *) if [ -z "$SCREEN_LOCK_MIN" ] || [ "$t" -gt "$SCREEN_LOCK_MIN" ]; then SCREEN_LOCK_MIN="$t"; fi ;;
      esac
    done
  fi
fi

# ---------------------------------------------------------------------------
# localAdmins — who can administer this box
#
# UID 0 accounts plus the members of the platform's admin group. Group members
# are reported as named, not recursively expanded: an unexpected NAME here is
# the finding, and expanding a directory group would turn one row into fifty.
# ---------------------------------------------------------------------------
collect_admins() {
  if [ "$OS" = "Darwin" ]; then
    dscl . -read /Groups/admin GroupMembership 2>/dev/null \
      | sed 's/^GroupMembership: //' | tr ' ' '\n'
    # Local accounts with UID 0.
    dscl . -list /Users UniqueID 2>/dev/null | awk '$2 == 0 {print $1}'
  else
    for g in sudo wheel admin adm root; do
      getent group "$g" 2>/dev/null | cut -d: -f4 | tr ',' '\n'
    done
    getent passwd 2>/dev/null | awk -F: '$3 == 0 {print $1}'
    # Anyone granted sudo directly in sudoers, excluding group entries and
    # the directives that are not principals.
    if [ -r /etc/sudoers ]; then
      awk '/^[^#%[:space:]]+[[:space:]]+ALL/ {print $1}' /etc/sudoers 2>/dev/null
    fi
    for f in /etc/sudoers.d/*; do
      [ -r "$f" ] || continue
      awk '/^[^#%[:space:]]+[[:space:]]+ALL/ {print $1}' "$f" 2>/dev/null
    done
  fi
}
LOCAL_ADMINS_JSON="$(collect_admins 2>/dev/null \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -v '^$' \
  | grep -v '^Defaults' \
  | sort -u \
  | json_array_from_lines)"

# ---------------------------------------------------------------------------
# cloudSyncClients
#
# PERSONAL cloud sync is the exfiltration path that matters: a staff member
# syncing a client folder into personal Dropbox is a disclosure. Detection is
# by installed client and by per-user sync directory, because either one means
# the path exists.
# ---------------------------------------------------------------------------
detect_cloud_sync() {
  if [ "$OS" = "Darwin" ]; then
    [ -d "/Applications/Dropbox.app" ] && echo "Dropbox"
    [ -d "/Applications/Google Drive.app" ] && echo "Google Drive"
    ls -d /Users/*/Library/CloudStorage/GoogleDrive-* >/dev/null 2>&1 && echo "Google Drive"
    [ -d "/Applications/OneDrive.app" ] && echo "OneDrive"
    ls -d /Users/*/Library/CloudStorage/OneDrive-Personal >/dev/null 2>&1 && echo "OneDrive (personal)"
    ls -d /Users/*/Library/CloudStorage/OneDrive-* >/dev/null 2>&1 && echo "OneDrive"
    ls -d /Users/*/Library/Mobile\ Documents/com~apple~CloudDocs >/dev/null 2>&1 && echo "iCloud Drive"
    [ -d "/Applications/Box.app" ] && echo "Box"
    [ -d "/Applications/MEGAsync.app" ] && echo "MEGA"
    [ -d "/Applications/pCloud Drive.app" ] && echo "pCloud"
    [ -d "/Applications/Nextcloud.app" ] && echo "Nextcloud"
    [ -d "/Applications/Sync.app" ] && echo "Sync.com"
  else
    ls -d /home/*/Dropbox >/dev/null 2>&1 && echo "Dropbox"
    have dropbox && echo "Dropbox"
    [ -d /opt/google/drive ] && echo "Google Drive"
    ls -d /home/*/OneDrive >/dev/null 2>&1 && echo "OneDrive"
    have onedrive && echo "OneDrive"
    have nextcloud && echo "Nextcloud"
    ls -d /home/*/Nextcloud >/dev/null 2>&1 && echo "Nextcloud"
    ls -d /home/*/MEGA >/dev/null 2>&1 && echo "MEGA"
    ls -d /home/*/pCloudDrive >/dev/null 2>&1 && echo "pCloud"
    ls -d /home/*/Box >/dev/null 2>&1 && echo "Box"
    # Flatpak/snap installs of the same clients.
    have flatpak && flatpak list --app --columns=application 2>/dev/null \
      | grep -Ei 'dropbox|nextcloud|megasync' | sed 's/.*\.//' || true
    have snap && snap list 2>/dev/null | awk 'NR>1 {print $1}' \
      | grep -Ei '^(dropbox|nextcloud-client|onedrive)' || true
  fi
}
CLOUD_SYNC_JSON="$(detect_cloud_sync 2>/dev/null | grep -v '^$' | sort -u | json_array_from_lines)"

# ---------------------------------------------------------------------------
# pendingReboot — patches installed but not in effect
# ---------------------------------------------------------------------------
PENDING_REBOOT=""
if [ "$OS" = "Darwin" ]; then
  # macOS does not expose a reliable flag. A staged update awaiting restart is
  # the closest signal; absent that, report null rather than a false "no".
  if [ -d /Library/Updates ] && [ -n "$(ls -A /Library/Updates 2>/dev/null)" ]; then
    PENDING_REBOOT=1
  elif have softwareupdate; then
    PENDING_REBOOT=0
  fi
else
  if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
    PENDING_REBOOT=1
  elif have needs-restarting; then
    if needs-restarting -r >/dev/null 2>&1; then PENDING_REBOOT=0; else PENDING_REBOOT=1; fi
  elif have dnf; then
    if dnf needs-restarting -r >/dev/null 2>&1; then PENDING_REBOOT=0; else PENDING_REBOOT=1; fi
  else
    # Running kernel older than the newest installed kernel = pending reboot.
    running="$(uname -r 2>/dev/null || true)"
    newest=""
    if have dpkg; then
      newest="$(dpkg -l 'linux-image-[0-9]*' 2>/dev/null | awk '/^ii/ {print $2}' \
                | sed 's/^linux-image-//' | sort -V | tail -1)"
    elif have rpm; then
      newest="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)"
    fi
    if [ -n "$running" ] && [ -n "$newest" ]; then
      case "$running" in
        "$newest"*) PENDING_REBOOT=0 ;;
        *) PENDING_REBOOT=1 ;;
      esac
    fi
  fi
fi

# ---------------------------------------------------------------------------
# mfaEnforced
#
# What an endpoint can honestly answer: is interactive or privileged access
# gated by something stronger than a password on THIS machine? Anything about
# the firm's IdP is decided server-side from Authentik and is not this script's
# to guess, so absence is null, never false.
# ---------------------------------------------------------------------------
MFA_ENFORCED=""
if [ "$OS" = "Darwin" ]; then
  if have pam_smartcard_check || grep -rqs 'pam_smartcard' /etc/pam.d/ 2>/dev/null; then
    MFA_ENFORCED=1
  fi
else
  if grep -rqs -E 'pam_(u2f|yubico|google_authenticator|oath|sss).*required' /etc/pam.d/ 2>/dev/null; then
    MFA_ENFORCED=1
  fi
fi

# ---------------------------------------------------------------------------
# Emit: ONE line, exactly the PostureSnapshot shape.
# ---------------------------------------------------------------------------
printf '{'
printf '"hostname":%s,'             "$(json_str "$HOSTNAME_VAL")"
printf '"collectedAt":%s,'          "$(json_str "$COLLECTED_AT")"
printf '"diskEncrypted":%s,'        "$(json_bool "$DISK_ENCRYPTED")"
printf '"avPresent":%s,'            "$(json_bool "$AV_PRESENT")"
printf '"avDefinitionsAgeDays":%s,' "$(json_num  "$AV_DEF_AGE")"
printf '"firewallOn":%s,'           "$(json_bool "$FIREWALL_ON")"
printf '"osPatchAgeDays":%s,'       "$(json_num  "$OS_PATCH_AGE")"
printf '"screenLockTimeoutMin":%s,' "$(json_num  "$SCREEN_LOCK_MIN")"
printf '"localAdmins":%s,'          "$LOCAL_ADMINS_JSON"
printf '"cloudSyncClients":%s,'     "$CLOUD_SYNC_JSON"
printf '"pendingReboot":%s,'        "$(json_bool "$PENDING_REBOOT")"
printf '"mfaEnforced":%s'           "$(json_bool "$MFA_ENFORCED")"
printf '}\n'
exit 0
