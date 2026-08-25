<#
.SYNOPSIS
  Sentinel Lite posture collector for Windows.

.DESCRIPTION
  Emits EXACTLY ONE LINE of JSON on stdout matching the PostureSnapshot
  interface in packages/shared/src/types.ts. Nothing else goes to stdout —
  the Wazuh wodle that runs this every 4 hours parses the line as-is, and any
  stray output breaks ingestion into asset_posture.

  Field contract (do not add, rename, or reorder-away any of these):
    hostname              string
    collectedAt           string  (ISO 8601, UTC)
    diskEncrypted         bool|null
    avPresent             bool|null
    avDefinitionsAgeDays  number|null
    firewallOn            bool|null
    osPatchAgeDays        number|null
    screenLockTimeoutMin  number|null
    localAdmins           string[]
    cloudSyncClients      string[]
    pendingReboot         bool|null
    mfaEnforced           bool|null   (optional in the interface; always emitted)

  null means "could not determine", which is NOT the same as false. A machine
  where BitLocker could not be queried must not be scored as unencrypted — the
  Security Six scorecard shows it as unknown and asks a human.

  USB history is collected too (§6) but is NOT part of PostureSnapshot, so it
  is written to a sidecar file rather than polluting the JSON line.

.NOTES
  PRIVACY: this collects security telemetry, not content. No keystrokes, no
  screenshots, no file contents. See the staff privacy notice.

  Runs as SYSTEM from a scheduled task every 4 hours. Never throws: every probe
  is individually guarded so one failing check yields null for that field
  instead of losing the whole snapshot.
#>

[CmdletBinding()]
param(
    # Where the USB-history sidecar goes. The Wazuh agent collects it separately.
    [string]$SidecarPath = "$env:ProgramData\VibeSentinel\usb-history.json"
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

function Get-OrNull {
    param([scriptblock]$Probe)
    try { & $Probe } catch { $null }
}

# --- hostname ---------------------------------------------------------------
$hostname = Get-OrNull { [System.Net.Dns]::GetHostName() }
if (-not $hostname) { $hostname = $env:COMPUTERNAME }

# --- collectedAt ------------------------------------------------------------
$collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# --- diskEncrypted: BitLocker on the system drive ---------------------------
# Only the system drive matters for the Security Six answer; a machine with an
# encrypted data disk and a clear-text C: is not encrypted.
$diskEncrypted = Get-OrNull {
    $vol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($null -eq $vol) { return $null }
    # ProtectionStatus On = key protectors active and volume encrypted.
    [bool]($vol.ProtectionStatus -eq 'On' -and $vol.VolumeStatus -ne 'FullyDecrypted')
}
if ($null -eq $diskEncrypted) {
    # Home editions and older builds have no BitLocker cmdlets; fall back to WMI.
    $diskEncrypted = Get-OrNull {
        $v = Get-CimInstance -Namespace 'root\CIMV2\Security\MicrosoftVolumeEncryption' `
                             -ClassName Win32_EncryptableVolume `
                             -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($null -eq $v) { return $null }
        [bool]($v.ProtectionStatus -eq 1)
    }
}

# --- avPresent + avDefinitionsAgeDays ---------------------------------------
# Defender first (the common case), then SecurityCenter2 for third-party AV.
$mp = Get-OrNull { Get-MpComputerStatus -ErrorAction Stop }

$avPresent = $null
$avDefinitionsAgeDays = $null

if ($mp) {
    # Defender is installed. "Present" means real-time protection is actually
    # on — a disabled Defender is not antivirus.
    $avPresent = [bool]($mp.AMServiceEnabled -and $mp.RealTimeProtectionEnabled)
    $lastUpdate = $mp.AntivirusSignatureLastUpdated
    if ($lastUpdate) {
        $avDefinitionsAgeDays = [int][math]::Floor(((Get-Date) - $lastUpdate).TotalDays)
    } elseif ($null -ne $mp.AntivirusSignatureAge) {
        $avDefinitionsAgeDays = [int]$mp.AntivirusSignatureAge
    }
    # Defender reports 65535 as "unknown / never updated", and an unset
    # timestamp can come back as an epoch date. Either would render as a
    # definition set decades old, which reads as a screaming alert instead of
    # the "we could not tell" it actually means.
    if ($null -ne $avDefinitionsAgeDays -and
        ($avDefinitionsAgeDays -ge 65535 -or $avDefinitionsAgeDays -gt 3650 -or $avDefinitionsAgeDays -lt 0)) {
        $avDefinitionsAgeDays = $null
    }
}

if ($null -eq $avPresent -or $avPresent -eq $false) {
    # Third-party AV registered with the Security Center. productState is a
    # bitfield: byte 2 (0x10) = real-time protection on, byte 3 (0x00) = defs
    # up to date. This is the documented-by-observation encoding Microsoft has
    # never formally published, so treat a parse failure as "unknown", not "no".
    $scResult = Get-OrNull {
        $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' `
                                      -ClassName AntiVirusProduct -ErrorAction Stop)
        if ($products.Count -eq 0) { return $null }
        $enabled = $false
        $bestAge = $null
        foreach ($p in $products) {
            $state = [int]$p.productState
            $rtp   = (($state -band 0x1000) -ne 0) -or ((($state -shr 8) -band 0x10) -ne 0)
            if ($rtp) { $enabled = $true }
            # Bit set in the low byte means definitions are OUT of date.
            $defsOutOfDate = (($state -band 0x10) -ne 0)
            $age = if ($defsOutOfDate) { 999 } else { 0 }
            if ($null -eq $bestAge -or $age -lt $bestAge) { $bestAge = $age }
        }
        [pscustomobject]@{ Present = $enabled; AgeDays = $bestAge }
    }
    if ($scResult) {
        if ($null -eq $avPresent -or $scResult.Present) { $avPresent = [bool]$scResult.Present }
        if ($null -eq $avDefinitionsAgeDays) { $avDefinitionsAgeDays = $scResult.AgeDays }
    }
}

# --- firewallOn: ALL profiles must be enabled -------------------------------
# Domain, Private, and Public. A laptop with Public disabled is exactly the
# machine that gets compromised in a coffee shop.
$firewallOn = Get-OrNull {
    $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
    if ($profiles.Count -eq 0) { return $null }
    [bool](-not ($profiles | Where-Object { -not $_.Enabled }))
}
if ($null -eq $firewallOn) {
    $firewallOn = Get-OrNull {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
        $all = @('DomainProfile','StandardProfile','PublicProfile') | ForEach-Object {
            (Get-ItemProperty -Path "$base\$_" -Name EnableFirewall -ErrorAction Stop).EnableFirewall
        }
        [bool](-not ($all | Where-Object { $_ -ne 1 }))
    }
}

# --- osPatchAgeDays: days since the last successful update install ----------
$osPatchAgeDays = Get-OrNull {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install'
    $t = (Get-ItemProperty -Path $key -Name LastSuccessTime -ErrorAction Stop).LastSuccessTime
    if (-not $t) { return $null }
    [int][math]::Floor(((Get-Date) - [datetime]::Parse($t)).TotalDays)
}
if ($null -eq $osPatchAgeDays) {
    # Fallback: newest hotfix InstalledOn. Less reliable (cumulative updates on
    # modern Windows do not always land here) but better than nothing.
    $osPatchAgeDays = Get-OrNull {
        $hf = Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop |
              Where-Object { $_.InstalledOn } |
              Sort-Object InstalledOn -Descending |
              Select-Object -First 1
        if (-not $hf) { return $null }
        [int][math]::Floor(((Get-Date) - [datetime]$hf.InstalledOn).TotalDays)
    }
}

# --- screenLockTimeoutMin ---------------------------------------------------
# The effective lock timeout, which requires BOTH a screensaver timeout AND
# "on resume, display logon screen". A screensaver that does not lock is not a
# screen lock, so that case reports null rather than a comforting number.
$screenLockTimeoutMin = Get-OrNull {
    # Machine policy wins over per-user settings.
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'
    $secure = (Get-ItemProperty -Path $policy -Name ScreenSaverIsSecure -ErrorAction SilentlyContinue).ScreenSaverIsSecure
    $timeout = (Get-ItemProperty -Path $policy -Name ScreenSaveTimeOut -ErrorAction SilentlyContinue).ScreenSaveTimeOut

    if ($null -eq $timeout) {
        # No policy: read the interactive users' hives under HKU and take the
        # LEAST secure (largest) value, because that is the real exposure.
        $worst = $null
        Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21-[\d-]+$' } |
            ForEach-Object {
                $p = "Registry::$($_.Name)\Control Panel\Desktop"
                $t = (Get-ItemProperty -Path $p -Name ScreenSaveTimeOut -ErrorAction SilentlyContinue).ScreenSaveTimeOut
                $s = (Get-ItemProperty -Path $p -Name ScreenSaverIsSecure -ErrorAction SilentlyContinue).ScreenSaverIsSecure
                if ($null -ne $t) {
                    if ([int]$s -ne 1) { return }   # does not lock; not a screen lock
                    $mins = [int][math]::Floor([int]$t / 60)
                    if ($null -eq $worst -or $mins -gt $worst) { $worst = $mins }
                }
            }
        return $worst
    }

    if ([int]$secure -ne 1) { return $null }   # times out but does not lock
    [int][math]::Floor([int]$timeout / 60)
}

# --- localAdmins ------------------------------------------------------------
# Every member of the local Administrators group, by SID-resolved name. Domain
# groups are reported as the group, not expanded — the point is "who can
# administer this box", and an unexpected name here is the finding.
$localAdmins = Get-OrNull {
    $group = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
    @(Get-LocalGroupMember -Group $group -ErrorAction Stop | ForEach-Object { $_.Name })
}
if ($null -eq $localAdmins) {
    # Get-LocalGroupMember throws on members whose SID cannot be resolved
    # (orphaned domain accounts). WinNT provider does not care.
    $localAdmins = Get-OrNull {
        $g = [ADSI]"WinNT://./Administrators,group"
        @($g.Invoke('Members') | ForEach-Object {
            try { ([ADSI]$_).InvokeGet('Name') } catch { $null }
        } | Where-Object { $_ })
    }
}
if ($null -eq $localAdmins) { $localAdmins = @() }

# --- cloudSyncClients -------------------------------------------------------
# PERSONAL cloud sync is the exfiltration path that matters: a staff member
# syncing a client folder into personal OneDrive or Dropbox is a disclosure.
# Business/tenant-managed OneDrive is reported separately so the two are never
# confused on the scorecard.
$cloudSyncClients = @()
$cloudProbes = @(
    @{ Name = 'OneDrive (personal)'; Test = {
        $u = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts\Personal' -ErrorAction SilentlyContinue
        [bool]$u -or (Test-Path "$env:USERPROFILE\OneDrive") } },
    @{ Name = 'OneDrive (business)'; Test = {
        [bool](Get-ChildItem 'HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts' -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like 'Business*' }) } },
    @{ Name = 'Dropbox'; Test = {
        (Test-Path "$env:LOCALAPPDATA\Dropbox\info.json") -or
        (Test-Path "$env:APPDATA\Dropbox\info.json") -or
        (Test-Path "${env:ProgramFiles(x86)}\Dropbox\Client\Dropbox.exe") } },
    @{ Name = 'Google Drive'; Test = {
        (Test-Path "$env:ProgramFiles\Google\Drive File Stream") -or
        (Test-Path "$env:LOCALAPPDATA\Google\DriveFS") -or
        (Test-Path "$env:ProgramFiles\Google\Drive") } },
    @{ Name = 'iCloud Drive'; Test = {
        (Test-Path "$env:ProgramFiles\Common Files\Apple\Internet Services\iCloudDrive.exe") -or
        (Test-Path "$env:USERPROFILE\iCloudDrive") } },
    @{ Name = 'Box'; Test = {
        (Test-Path "$env:LOCALAPPDATA\Box\Box\data") -or
        (Test-Path "$env:ProgramFiles\Box\Box\Box.exe") } },
    @{ Name = 'Sync.com'; Test = { Test-Path "$env:LOCALAPPDATA\Sync\sync.exe" } },
    @{ Name = 'pCloud'; Test = { Test-Path "$env:LOCALAPPDATA\pCloud" } },
    @{ Name = 'MEGA'; Test = { Test-Path "$env:LOCALAPPDATA\MEGAsync" } }
)
foreach ($probe in $cloudProbes) {
    $found = Get-OrNull $probe.Test
    if ($found) { $cloudSyncClients += $probe.Name }
}
$cloudSyncClients = @($cloudSyncClients | Select-Object -Unique)

# --- pendingReboot ----------------------------------------------------------
# A pending reboot means patches are installed but not in effect, which is the
# gap between "patched" on paper and patched in fact.
$pendingReboot = Get-OrNull {
    $indicators = @(
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'),
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'),
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'),
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'),
        ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                    -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations)
    )
    # A rename pending on a computer-name change also counts.
    $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $target = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $target -and ($active -ne $target)) { $indicators += $true }
    [bool]($indicators -contains $true)
}

# --- mfaEnforced ------------------------------------------------------------
# What an endpoint can honestly answer: is interactive logon gated by something
# stronger than a password? Windows Hello for Business provisioned, or a smart
# card required. Anything about the firm's IdP is decided server-side from
# Authentik and is not this script's to guess, so absence here is null.
$mfaEnforced = Get-OrNull {
    $scForce = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                -Name scforceoption -ErrorAction SilentlyContinue).scforceoption
    if ($scForce -eq 1) { return $true }
    $whfb = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork' -ErrorAction SilentlyContinue
    $enabled = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork' `
                -Name Enabled -ErrorAction SilentlyContinue).Enabled
    if ($enabled -eq 1 -or $whfb) { return $true }
    $null
}

# ---------------------------------------------------------------------------
# USB history sidecar (§6). NOT part of PostureSnapshot — written separately so
# the JSON line stays exactly the shape the parser expects.
# ---------------------------------------------------------------------------
try {
    $usb = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $devClass = $_.PSChildName
            Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    deviceClass  = $devClass
                    serial       = $_.PSChildName
                    friendlyName = $props.FriendlyName
                    firstSeen    = $props.'0064'      # DEVPKEY_Device_InstallDate, when present
                }
            }
        })
    $sidecarDir = Split-Path -Parent $SidecarPath
    if (-not (Test-Path $sidecarDir)) { New-Item -ItemType Directory -Path $sidecarDir -Force | Out-Null }
    [pscustomobject]@{
        hostname    = $hostname
        collectedAt = $collectedAt
        usbDevices  = $usb
    } | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $SidecarPath -Encoding UTF8
} catch {
    # A missing USB history must never cost us the posture snapshot.
}

# ---------------------------------------------------------------------------
# Emit: ONE line, exactly the PostureSnapshot shape.
#
# [string[]] casts on the two array fields matter — ConvertTo-Json renders a
# bare single-element collection as a scalar, which would fail the parser's
# schema check on any machine with exactly one local admin.
# ---------------------------------------------------------------------------
$snapshot = [ordered]@{
    hostname             = [string]$hostname
    collectedAt          = [string]$collectedAt
    diskEncrypted        = $diskEncrypted
    avPresent            = $avPresent
    avDefinitionsAgeDays = $avDefinitionsAgeDays
    firewallOn           = $firewallOn
    osPatchAgeDays       = $osPatchAgeDays
    screenLockTimeoutMin = $screenLockTimeoutMin
    localAdmins          = [string[]]@($localAdmins)
    cloudSyncClients     = [string[]]@($cloudSyncClients)
    pendingReboot        = $pendingReboot
    mfaEnforced          = $mfaEnforced
}

$json = $snapshot | ConvertTo-Json -Depth 3 -Compress
# ConvertTo-Json never emits newlines with -Compress, but be certain: the wodle
# reads one line.
[Console]::Out.WriteLine(($json -replace "`r?`n", ''))
exit 0
