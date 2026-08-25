<#
.SYNOPSIS
  Installs the firm's Vibe Print queues on a Windows workstation over IPP.

.DESCRIPTION
  Adds one Windows printer per firm queue, pointed at the Vibe Print gateway
  over the mesh using IPP Everywhere. No vendor driver is installed and no
  physical printer IP is ever configured on the workstation — that is the whole
  point of the print isolation model (§2.2): the gateway is the sole IPP/LPD/
  raw-9100 client on the network.

  IPP Everywhere means Windows negotiates the driver from the gateway itself
  ("Microsoft IPP Class Driver"), so there is nothing per-model to maintain and
  nothing to break when a printer is replaced.

  Run AFTER the NetBird client is enrolled — the gateway hostname resolves and
  routes over the mesh only.

  Placeholders are filled in by lite/generate-lite.sh.

.NOTES
  Idempotent: re-running updates existing queues rather than duplicating them.
#>

[CmdletBinding()]
param(
    [string]$Gateway = '@@PRINT_GATEWAY@@',
    [int]$Port = 631,
    # Firm queues. generate-lite.sh can extend this list from the Sentinel
    # inventory; these two are the defaults every firm gets.
    [string[]]$Queues = @('Secure - Client Docs', 'General')
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$m) Write-Host "[print-queue] $m" }

# --- The gateway must be reachable, or we are installing dead queues --------
Write-Step "Checking the gateway is reachable over the mesh: $Gateway`:$Port"
$reachable = Test-NetConnection -ComputerName $Gateway -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
if (-not $reachable) {
    throw @"
Cannot reach the Vibe Print gateway at ${Gateway}:${Port}.

This almost always means the NetBird client is not enrolled yet. The gateway
listens on the mesh interface ONLY, so it is unreachable until this machine is
a peer. Enrol NetBird first, then re-run this script.
"@
}
Write-Step "Gateway reachable."

foreach ($queue in $Queues) {
    # The IPP endpoint CUPS publishes for a queue: /printers/<name>, with
    # spaces encoded the way CUPS names them.
    $cupsName = ($queue -replace '[^A-Za-z0-9_-]', '_')
    $uri      = "ipps://${Gateway}:${Port}/printers/$cupsName"
    $portName = "IPP_${cupsName}"

    Write-Step "Queue '$queue' → $uri"

    try {
        # Port
        $existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
        if (-not $existingPort) {
            Add-PrinterPort -Name $portName -PrinterHostAddress $Gateway -ErrorAction Stop
        }

        # Driver: IPP Everywhere / IPP Class Driver, negotiated from the gateway.
        $driverName = 'Microsoft IPP Class Driver'
        if (-not (Get-PrinterDriver -Name $driverName -ErrorAction SilentlyContinue)) {
            Add-PrinterDriver -Name $driverName -ErrorAction Stop
        }

        $existing = Get-Printer -Name $queue -ErrorAction SilentlyContinue
        if ($existing) {
            Set-Printer -Name $queue -PortName $portName -DriverName $driverName -ErrorAction Stop
            Write-Step "  updated existing queue"
        } else {
            Add-Printer -Name $queue -DriverName $driverName -PortName $portName -ErrorAction Stop
            Write-Step "  installed"
        }

        # Comment carries the release policy so a user who checks printer
        # properties sees why an off-site job did not come out immediately.
        Set-PrinterProperty -PrinterName $queue -PropertyName 'Config:Comment' `
            -Value 'Vibe Print. On-site: prints immediately. Off-site: held for release at the device.' `
            -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Could not install queue '$queue': $($_.Exception.Message)"
    }
}

# --- Default printer -------------------------------------------------------
# 'General' as the default, so a user who does not think about it does not send
# client documents to a queue with a different release policy.
$default = $Queues | Where-Object { $_ -eq 'General' } | Select-Object -First 1
if (-not $default) { $default = $Queues | Select-Object -First 1 }
if ($default -and (Get-Printer -Name $default -ErrorAction SilentlyContinue)) {
    try {
        (Get-CimInstance -ClassName Win32_Printer -Filter "Name='$($default -replace "'","''")'").SetDefaultPrinter() | Out-Null
        Write-Step "Default printer set to '$default'"
    } catch {
        Write-Warning "Could not set the default printer: $($_.Exception.Message)"
    }
}

Write-Step "Done. Printing goes through the gateway only; direct printer access is blocked by block-printer-egress.ps1."
exit 0
