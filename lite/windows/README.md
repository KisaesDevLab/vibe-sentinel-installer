# Sentinel Lite — Windows bundle

`lite/generate-lite.sh` stages this directory per firm, substituting the
`@@PLACEHOLDER@@` values. What lands in `<out>/windows/` is a ready-to-build
WiX project; the actual `.exe` is produced on a Windows box, because WiX and
Authenticode signing both require one.

## What the bundle installs, and in what order

The order is the design, not an implementation detail:

| # | Package | Why here |
|---|---|---|
| 1 | **NetBird** | Enrolled FIRST with a one-time setup key scoped to the `workstations` group. Every Sentinel service — the Wazuh manager, the print gateway, Vaultwarden — binds the mesh interface only. Nothing later can reach its server until this peer is up. |
| 2 | `wait-for-mesh.exe` | Blocks until the mesh interface is up and the manager resolves and answers on 1515. Without it a fast machine races the mesh and produces an agent that looks enrolled and reports nothing. |
| 3 | **Wazuh agent** | Registers over the mesh, by name, with the firm enrollment password. |
| 4 | **Sysmon** | Tuned SwiftOnSecurity-derived config for process/network/file visibility. |
| 5 | **Sentinel Lite payload** | Posture collector + 4-hour scheduled task, firm print queues over IPP Everywhere, printer-egress firewall rules. |

Install Wazuh before NetBird and the install still "succeeds". That is the
failure mode this ordering exists to prevent.

## Files

| File | What |
|---|---|
| `sentinel-lite.wxs` | The Burn **bundle**: chains the four packages above. |
| `sentinel-lite-payload.wxs` | The Kisaes-authored **MSI**: our files, the scheduled task, print queues, firewall rules. |
| `wait-for-mesh.ps1` | Compiled to `wait-for-mesh.exe` at build time. |
| `payload/` | Staged by `generate-lite.sh`, plus the third-party binaries you supply. |

## What you must drop into `payload/` before building

`generate-lite.sh` stages our own files. These are third-party and are not
redistributed in this repo — download each from its vendor and verify the
checksum before it goes into a firm's installer:

| File | Where from |
|---|---|
| `netbird_installer.msi` | NetBird releases, matching the pinned management version in `versions/manifest.json` |
| `wazuh-agent.msi` | Wazuh packages, **matching the manager version** — a mismatched agent may register and then fail to send |
| `Sysmon64.exe` | Sysinternals |
| `sysmon-config.xml` | The firm's tuned config (SwiftOnSecurity-derived); ships with the rule pack |
| `sentinel.ico`, `sentinel-logo.png`, `theme.xml` | Branding for the bootstrapper UI |

`generate-lite.sh` stages, into `payload/`:

- `posture.ps1` — the collector (unmodified; it must emit exactly one
  `PostureSnapshot` JSON line)
- `install-queues.ps1` — IPP Everywhere queue install
- `block-printer-egress.ps1` — printer isolation rules
- `enrollment.json` — the firm's enrollment facts

## Build

On a Windows machine with the **WiX v3 Toolset** and PowerShell:

```powershell
# 1. wait-for-mesh.exe
Install-Module ps2exe -Scope CurrentUser -Force
Invoke-PS2EXE .\wait-for-mesh.ps1 .\payload\wait-for-mesh.exe

# 2. The payload MSI
candle.exe sentinel-lite-payload.wxs -ext WixUtilExtension
light.exe  sentinel-lite-payload.wixobj -ext WixUtilExtension `
           -out payload\sentinel-lite-payload.msi

# 3. The bundle
candle.exe sentinel-lite.wxs -ext WixBalExtension -ext WixUtilExtension
light.exe  sentinel-lite.wixobj -ext WixBalExtension -ext WixUtilExtension `
           -out SentinelLite-@@FIRM_SLUG@@.exe

# 4. SIGN IT
signtool.exe sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
             /a SentinelLite-@@FIRM_SLUG@@.exe
```

**Step 4 is not optional.** An unsigned bundle trains staff to click through
SmartScreen warnings, which is exactly the behaviour the phishing detection
pack exists to catch. Do not ship one.

## Deploying

```powershell
# Interactive
.\SentinelLite-@@FIRM_SLUG@@.exe

# Silent (RMM, GPO startup script, Intune)
.\SentinelLite-@@FIRM_SLUG@@.exe /quiet /log C:\Windows\Temp\sentinel-lite.log
```

The bundle refuses to run on anything older than Windows 10 build 17763 — the
posture collector depends on `Get-MpComputerStatus` and
`Get-NetFirewallProfile`.

## Handling

**This directory contains credentials**: a NetBird setup key and the Wazuh
enrollment password, both baked into the built `.exe`. Treat the built
installer like a password:

- Move it over the mesh or on encrypted media. Never email it.
- The setup key is one-time by default. A bundle that leaks is a bundle that
  has already been spent — but the Wazuh enrollment password in it is not
  one-time, so a leak still matters.
- Generate a fresh bundle per batch of machines and delete it when the batch
  is enrolled.

## Verifying an install

Within 10 minutes of a successful install (the Phase 7 acceptance bar):

1. The asset appears in the Sentinel UI with **full posture**, not partial.
2. `Get-ScheduledTask -TaskPath '\VibeSentinel\'` shows `PostureCollection`
   with a 4-hour repetition.
3. `Get-Printer` lists the firm queues; a test page prints.
4. Browsing to a printer's IP does **not** load its admin page — that is the
   print isolation working end to end.
5. `Get-NetFirewallRule -Group 'Vibe Sentinel - Print Isolation'` returns the
   allow and block rules.

## Uninstalling

Use Add/Remove Programs, or:

```powershell
.\SentinelLite-@@FIRM_SLUG@@.exe /uninstall /quiet
```

This removes the payload, the scheduled task, and the firewall rules. **It
leaves NetBird, the Wazuh agent, and Sysmon installed** — removing them is a
separate, deliberate step, because pulling an endpoint out of monitoring should
never be a side effect of uninstalling something else. Agent removal also
raises a tamper alert by design (§6).

## Privacy

Sentinel Lite collects security telemetry, not content. No keystrokes, no
screenshots, no file contents. Activity reports show *that* a file was
accessed, not what it contained. Tell staff before this lands on their machine
— the notice belongs in the WISP, and `enrollment.json` carries the same text.
