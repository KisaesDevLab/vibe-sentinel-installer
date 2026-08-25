<#
.SYNOPSIS
  Blocks until the NetBird mesh is up and the Wazuh manager resolves.

.DESCRIPTION
  Chained between the NetBird package and the Wazuh package in
  sentinel-lite.wxs. Without it, a fast machine races the mesh: the NetBird MSI
  returns as soon as the service starts, the Wazuh agent immediately tries to
  register against a hostname that does not resolve yet, and the install
  "succeeds" while producing an agent that never reports.

  Compiled to wait-for-mesh.exe at bundle-build time (Burn's ExePackage needs a
  real executable, not a script):

      Install-Module ps2exe -Scope CurrentUser
      Invoke-PS2EXE .\wait-for-mesh.ps1 .\payload\wait-for-mesh.exe -noConsole:$false

  Exit codes:
    0  mesh is up and the manager resolves
    1  timed out — the bundle treats this as fatal (Vital="yes"), because an
       agent that cannot reach its manager is worse than a failed install: it
       looks enrolled and reports nothing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Manager,
    [int]$TimeoutSeconds = 180,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'SilentlyContinue'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)

Write-Host "[wait-for-mesh] Waiting for the NetBird interface and for '$Manager' to resolve (timeout ${TimeoutSeconds}s)..."

while ((Get-Date) -lt $deadline) {

    # 1. Is the NetBird service running and does it have an interface?
    $svc = Get-Service -Name 'NetBird' -ErrorAction SilentlyContinue
    $hasInterface = $false
    if ($svc -and $svc.Status -eq 'Running') {
        $hasInterface = [bool](Get-NetAdapter -ErrorAction SilentlyContinue |
                               Where-Object { $_.InterfaceDescription -match 'NetBird|Wintun' -and $_.Status -eq 'Up' })
    }

    # 2. Does the manager hostname resolve? NetBird DNS serves the firm's
    #    §2.6 hostnames, so resolution is the real readiness signal.
    $resolves = $false
    if ($hasInterface) {
        try {
            $addrs = [System.Net.Dns]::GetHostAddresses($Manager)
            $resolves = ($addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' }).Count -gt 0
        } catch { $resolves = $false }
    }

    # 3. Is the registration port actually open across the mesh?
    if ($resolves) {
        $open = Test-NetConnection -ComputerName $Manager -Port 1515 `
                    -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($open) {
            Write-Host "[wait-for-mesh] Mesh is up; $Manager`:1515 reachable. Continuing."
            exit 0
        }
    }

    Start-Sleep -Seconds $PollSeconds
}

Write-Error @"
[wait-for-mesh] Timed out after ${TimeoutSeconds}s.

The NetBird client did not come up, or '$Manager' is not reachable on the mesh.
Check, in this order:
  1. Is the NetBird service running?            Get-Service NetBird
  2. Did the setup key work, or was it already spent?
     A one-time key that has been used will fail silently on a second machine —
     generate a fresh bundle.
  3. Does the peer appear in the NetBird admin UI in the 'workstations' group?
  4. Is the Sentinel host itself enrolled? The Wazuh manager binds the mesh
     interface only, so it is unreachable until the host is a peer.

Stopping here on purpose: an agent that cannot reach its manager looks enrolled
and reports nothing, which is worse than a failed install.
"@
exit 1
