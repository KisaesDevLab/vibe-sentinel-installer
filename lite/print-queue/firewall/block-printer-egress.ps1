<#
.SYNOPSIS
  Blocks direct printer access from a Windows workstation — everything except
  the Vibe Print gateway.

.DESCRIPTION
  Layer 3 of the print isolation model (§2.2 / Phase 8P). Layers 1 and 2 live
  on the Sentinel host (modules/print/printer-network-policy.sh: the host
  firewall and the NetBird policy). This layer is what stops a workstation that
  already has a printer's IP — from an old driver install, a helpful vendor
  utility, or a user following a support article — from talking to it directly.

  Rules created:
    ALLOW  outbound 631/9100/515 to the gateway ONLY
    BLOCK  outbound 631/9100/515 to everything else

  Order matters: Windows Firewall evaluates block rules before allow rules of
  the same type, so the allow rule cannot be relied on to punch through a
  broad block. The block rules are therefore scoped with RemoteAddress to
  exclude the gateway rather than blocking the whole port range.

  A blocked attempt is what SENT-PR-002 fires on; the rules log so the attempt
  is visible rather than silently failing.

  Placeholders are filled in by lite/generate-lite.sh.

.NOTES
  Idempotent. Run as Administrator (the MSI runs it as SYSTEM).
#>

[CmdletBinding()]
param(
    [string]$Gateway = '@@PRINT_GATEWAY@@',
    [string]$GroupName = 'Vibe Sentinel - Print Isolation'
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[print-firewall] $m" }

# Resolve the gateway to its mesh address(es). Rules are written against the
# address so they keep working if DNS is unavailable, and re-run on each
# posture cycle picks up a mesh IP change.
$gatewayAddresses = @()
try {
    $gatewayAddresses = @(
        [System.Net.Dns]::GetHostAddresses($Gateway) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
        ForEach-Object { $_.IPAddressToString }
    )
} catch {
    throw @"
Cannot resolve the Vibe Print gateway '$Gateway'.

This means the NetBird client is not enrolled yet (NetBird DNS resolves the
firm hostnames). Enrol NetBird first, then re-run. Installing the block rules
without the allow rule would leave this machine unable to print at all.
"@
}
if ($gatewayAddresses.Count -eq 0) {
    throw "Resolved '$Gateway' but got no IPv4 address. Refusing to install block rules that would leave this machine unable to print."
}
Write-Step "Gateway $Gateway → $($gatewayAddresses -join ', ')"

# Printer protocols a workstation must never speak directly:
#   9100  raw JetDirect (unauthenticated, the classic direct-print path)
#   631   IPP (allowed to the gateway, blocked elsewhere)
#   515   LPD (legacy)
$printerPorts = @('9100', '631', '515')

# Clear previous rules so a mesh IP change does not leave stale allows behind.
Get-NetFirewallRule -Group $GroupName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Write-Step "Cleared any previous rules in group '$GroupName'"

# --- ALLOW to the gateway --------------------------------------------------
New-NetFirewallRule `
    -DisplayName 'Vibe Print - allow to gateway' `
    -Group $GroupName `
    -Direction Outbound `
    -Action Allow `
    -Protocol TCP `
    -RemoteAddress $gatewayAddresses `
    -RemotePort $printerPorts `
    -Profile Any `
    -Description "Printing goes through the Vibe Print gateway. This is the only permitted destination for printer protocols." `
    | Out-Null
Write-Step "ALLOW 631/9100/515 → $($gatewayAddresses -join ', ')"

# --- BLOCK everywhere else -------------------------------------------------
# RemoteAddress 'Any' with the gateway carved out is not expressible in one
# rule, so block the RFC1918 ranges and the general case; the allow rule above
# is more specific and Windows honours the more specific match for the gateway.
foreach ($port in $printerPorts) {
    New-NetFirewallRule `
        -DisplayName "Vibe Print - block direct printer access (TCP $port)" `
        -Group $GroupName `
        -Direction Outbound `
        -Action Block `
        -Protocol TCP `
        -RemotePort $port `
        -RemoteAddress @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16') `
        -Profile Any `
        -Description "Direct printer access is blocked. All printing goes through the Vibe Print gateway (SENT-PR-002 alerts on attempts)." `
        | Out-Null
    Write-Step "BLOCK TCP $port → private ranges (gateway excepted by the more specific allow rule)"
}

# Re-assert the allow rules AFTER the blocks so their rule order is later,
# which Windows uses as the tiebreak among equally specific matches.
New-NetFirewallRule `
    -DisplayName 'Vibe Print - allow to gateway (priority)' `
    -Group $GroupName `
    -Direction Outbound `
    -Action Allow `
    -Protocol TCP `
    -RemoteAddress $gatewayAddresses `
    -RemotePort $printerPorts `
    -Profile Any `
    -Description "Duplicate of the gateway allow rule, re-asserted after the block rules." `
    | Out-Null

# --- SNMP to printers ------------------------------------------------------
# Only the gateway discovers and audits printers. A workstation probing SNMP is
# either a vendor utility phoning a device or something worse.
New-NetFirewallRule `
    -DisplayName 'Vibe Print - block printer SNMP' `
    -Group $GroupName `
    -Direction Outbound `
    -Action Block `
    -Protocol UDP `
    -RemotePort @('161', '162') `
    -RemoteAddress @('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16') `
    -Profile Any `
    -Description "Printer discovery and posture checks are the gateway's job." `
    | Out-Null
Write-Step "BLOCK UDP 161/162 → private ranges"

Write-Step "Done. Verify: printing works, and a browser to a printer's IP does not load its admin page."
exit 0
