# vibe-sentinel-installer

The standalone installer for **Vibe Sentinel** — a security monitoring and
compliance appliance for tax and accounting firms, built around the FTC
Safeguards Rule and IRS Pub 4557.

Sentinel is its own appliance, not a module of the Vibe Appliance. It can share
a host with other Vibe products or run on a dedicated box; the preflight checks
which of those you are doing and refuses to proceed if the host cannot carry it.

```bash
curl -fsSL https://get.vibesentinel.app/install.sh | bash
```

Or from a checkout:

```bash
sudo bash install.sh
sudo bash install.sh --modules core,runtime,edge,mesh,keys,pulse,print,ai
sudo bash install.sh --unattended --config firm.json
```

The installer is interactive by default: a wizard collects the firm profile,
then two rounds of preflight run, then the stack comes up in a fixed order with
a health gate on every step. **A failed gate halts with the step name and what
to do about it.** It never leaves a half-built stack running.

---

## Before you start

Have these five things ready. Every one of them is a preflight check, and every
one of them is a first install that stalls when it is discovered late.

### 1. A domain on Cloudflare

The firm's own domain, or a Kisaes-provided `<firm>.vibesentinel.app` subzone.
All hostnames hang under it. The zone must be **active** in Cloudflare.

### 2. A Cloudflare API token with these scopes

The preflight verifies each one and names the missing scope if it fails:

| Scope | Why |
|---|---|
| Zone → DNS → Edit | The §2.6 hostname records, and ACME DNS-01 for the wildcard cert |
| Account → Cloudflare Tunnel → Edit | Creating and configuring the tunnel |
| Access → Apps and Policies → Edit | Dashboards behind Access; machine endpoints bypassed |
| Zone → Zone Settings → Edit | Turning on gRPC proxying, without which NetBird will not work |
| Zone → WAF / Rate Limiting → Edit | The Vaultwarden token-endpoint rate limits in tunnel mode |

The token is stored as a Docker secret, never in the config file.

### 3. An SMTP relay

Host, port, username, password. Required for Vaultwarden invitations, Authentik
enrollment, and email alerts. **The preflight sends a real test message** — a
relay that accepts the connection but rejects the send fails here, not three
weeks later when the first alert does not arrive.

### 4. Firm answers

- Legal name and state; QI name and email (the QI becomes the Authentik admin)
- **Consumer-count estimate** — this decides whether the firm is subject to the
  full Safeguards Rule or the small-business exemption (REQ-019). Sentinel
  labels the result "mandatory" or "voluntary" and does not guess.
- Staff countries, business hours, backup window, maintenance window
- **On-premises subnets** — label each print job as on-premises or not in the
  audit log, and scope the printer-isolation firewall rules. Verified against the
  host's own interfaces. Every job prints on submission; there is no hold.
- Agent-count estimate — drives the disk requirement

### 5. A host that meets the resource floor

| | CPU | RAM |
|---|---|---|
| `core` (required, includes Authentik) | 4 cores | 8 GB |
| `+ mesh` | +1 core | +1 GB |
| `+ keys` | +0.5 | +512 MB |
| `+ pulse` | +0.5 | +512 MB |
| `+ print` | +0.5 | +512 MB |
| `+ scan` | +2 cores | +4 GB |

**Free**, not merely installed — on a shared Vibe host the preflight measures
`MemAvailable`. Disk is computed from agent count × retention with 30% headroom
and the installer refuses below it.

---

## Modules

`core` is required. Disabling a default-on **Security Six** module (`mesh`,
`keys`, `pulse`, `print`) requires recording a compensating control — "firm
uses Tailscale", "firm uses 1Password Business" — so the scorecard still has an
answer. The installer refuses without one.

| id | What it ships | Default | Extra resources |
|---|---|---|---|
| `core` | sentinel web/api/worker, Postgres 16, Redis, Authentik, certs sidecar (ACME DNS-01 wildcard), ntfy, Wazuh manager/indexer/dashboard, cloudflared, built-in restic backup | **required** | 4 cores / 8 GB |
| `runtime` | Falco + falcosidekick. Modern eBPF with a minimal capability set, not `--privileged` | on | — |
| `edge` | CrowdSec + nftables bouncer + a Cloudflare Worker bouncer | on | — |
| `mesh` | NetBird management/signal/dashboard. Relay sub-module **off** (direct-only, zero inbound ports) | on | 1 core / 1 GB |
| `keys` | Vaultwarden on the shared Postgres, separate database | on | 0.5 / 512 MB |
| `pulse` | Uptime Kuma v2, pinned; monitors auto-managed from inventory | on | 0.5 / 512 MB |
| `print` | Vibe Print gateway — HTTP print API, controlled egress to every printer | on | 0.5 / 512 MB |
| `scan` | Greenbone / OpenVAS, loopback-only web UI | **off** | 2 cores / 4 GB |
| `ai` | vibe-ai-router client config. **No container** | on (local) | — |

### Where a module's facts live

Each module ships a `manifest.json`. It is the single source for the module's
host ports, CPU and RAM floor, host prerequisites, boot order, upgrade gate and
ingress — and `preflight/ports.sh`, `preflight/resources.sh` and `install.sh`
read it rather than carrying their own copies.

They used to carry copies, and the copies had drifted: the port map was missing
443 (Vaultwarden) and 3001 (Uptime Kuma) entirely while still listing six ports
for a print module that no longer publishes them, and nothing in any single
file made that visible. `scripts/check-manifests.py` now verifies the manifest
against `compose.yml`, `versions/manifest.json` and `install.sh` on every push;
it caught a boot-order contradiction on its first run.

The manifest conforms to the **Vibe Appliance's** per-app schema, vendored at
`.schema/manifest.schema.json`. That is what lets the appliance's console list
Sentinel modules in the same catalog as Vibe apps without either side learning
the other's internals — the appliance reads the manifest and renders *nothing*
for it (no vhost, no emergency frontend, no tunnel ingress), because Sentinel
owns its own runtime and its own ingress.

### Turning one module on or off after install

`install.sh` selects modules once and brings the whole stack up in §2.6 order.
For a single module afterwards:

```bash
sudo bash modules/module.sh status
sudo bash modules/module.sh enable pulse
sudo bash modules/module.sh disable pulse      --reason "firm uses Better Uptime" --approver "Jane Smith, QI"
```

This is also what the Vibe Appliance's console calls when an operator clicks
Enable or Disable on a Sentinel row, so both paths converge on one script.

Three things it refuses:

- **`core`** — every other module depends on it, so turning it off is tearing
  the appliance down. That is `uninstall.sh`, which exports the firm's
  compliance artifacts first.
- **A Security Six module without a compensating control.** `mesh`, `keys`,
  `pulse` and `print` need `--reason` and `--approver`; the answer is recorded
  in `config.json` under `compensating_controls`. A firm may legitimately use
  Tailscale instead of NetBird, but the scorecard still needs an answer.
- **A module whose `requiredApps` are not themselves enabled** — it would start
  and immediately fail, and the operator would read container logs to learn
  something this refusal says in one sentence.

Data is never removed by either direction. Re-enabling picks the volumes
straight back up.

### Notes on the ones with sharp edges

**`keys`** — Vaultwarden publishes in one of two modes, chosen in the wizard:

- **tunnel** (what most firms should pick): through the Cloudflare Tunnel with
  *no* Access login on the client paths, because Bitwarden desktop, browser,
  and mobile apps cannot complete an interactive Access login. Protected
  instead by Vaultwarden's own auth with enforced 2FA, Cloudflare WAF, rate
  limits on `/identity/connect/token` and `/api/accounts/prelogin`, CrowdSec on
  the logs, and an Access policy on `/admin` **only**. Phones and home machines
  work without the mesh client.
- **mesh_only**: no public hostname; every device including phones runs the
  NetBird client.

`ADMIN_TOKEN` is unset at rest — the `/admin` panel does not exist in
production. Open it with:

```bash
sudo bash /etc/vibe-sentinel/modules/keys/maintenance-mode.sh --on \
     --reason "rotate the org RSA key" --approver "Jane Smith, QI"
```

That sets an argon2id hash, restarts the container, prints a one-time token
once, and **schedules an automatic revert 30 minutes later**. A window that
cannot be guaranteed to close is refused outright.

**`print`** — Vibe Print is the only thing on the network allowed to talk to a
printer, and that isolation is what the module delivers today. **No content
inspection, ever** (Decision 24) — and with the current product that holds
structurally, not by configuration: the gateway is handed a payload by a caller
and renders it, so there is no print stream to intercept.

> **Retargeted 2026-08-28, and narrower than originally planned.** This module
> referenced three images — `vibe-print`, `vibe-print-release` and
> `vibe-print-scanner-inbox` — that no repository builds, so it could never
> have started. It now runs `ghcr.io/kisaesdevlab/vibe-printer`, the image the
> Vibe-Printer repo actually publishes and the same one the Vibe Appliance
> installs: one packaging of one product across both appliances.
>
> That product is an **API print gateway**, not a print server. Callers POST to
> `/v1/print` on the mesh and it dials **out** to the device (tcp/9100, tcp/631,
> or its internal CUPS). Three things the original design assumed do not exist
> yet, and the firm's scorecard must not claim them:
>
> - **IPP Everywhere queue publishing** — workstations see no virtual queues.
> - **Held release with PIN/web release at the device** — no longer wanted.
>   Decision 26 was **withdrawn** (build plan v1.7, §11 R26) rather than left as
>   a claim nothing could enforce: every job prints on submission, and the
>   control plane's rules, schema and reports no longer describe holding.
> - **The scanner inbox** (SMB/FTPS/SMTP) — so SENT-PR-009's scan-destination
>   control has no enforcement point.
>
> All three are tracked as features of `KisaesDevLab/Vibe-Printer`. The host
> port map shrank from eight entries to one as a result, which is a reduction in
> exposed surface rather than a regression.

After install, run:

```bash
sudo bash /etc/vibe-sentinel/modules/print/printer-network-policy.sh \
     --subnets 10.20.0.0/24
```

**`pulse`** — Uptime Kuma's socket.io API is unversioned and changes between
releases. The version is pinned and upgrades are harness-gated; a break here is
silent, not loud.

**`scan`** — off by default and worth leaving off unless the firm has network
gear or printers to scan. Wazuh's vulnerability detector already covers
installed packages on every agent. Needs two env keys added by hand before it
will build — see `modules/scan/env.schema`.

---

## Hostnames and ports

All hostnames are created automatically under the firm domain.

| Hostname | Published via | Behind Access |
|---|---|---|
| `sentinel.` | Tunnel | yes |
| `wazuh.` | Tunnel | yes |
| `id.` (Authentik) | Tunnel | admin UI only; OIDC paths bypassed |
| `nb.` / `nb-signal.` | Tunnel (gRPC, `http2Origin`) | **bypassed** — machine-facing |
| `nb-admin.` | Tunnel | yes |
| `vault.` | Tunnel or mesh, per mode | `/admin*` only |
| `status.` | Tunnel | status path bypassed if enabled |
| `print.` | **Mesh only** | n/a |
| `ntfy.` | **Mesh only** | n/a |

Mesh-only names are public DNS A records pointing at **mesh IPs** — private
addresses in public DNS are allowed — with one wildcard `*.<domain>` cert from
ACME DNS-01 through Cloudflare. No private CA anywhere, so Bitwarden clients,
browsers, and IPP clients all trust it out of the box. No `.internal` or
`.local` names, ever: they cannot get public certificates.

### Host port map (§2.6)

The preflight checks every one of these for conflicts, including against other
Vibe appliances on the same host.

| Port | Service | Bound to |
|---|---|---|
| — | Sentinel API/web | no host port; tunnel/mesh only |
| 1514/tcp, 1515/tcp | Wazuh agents | **mesh interface** |
| 55000/tcp | Wazuh API | loopback |
| 9200/tcp | OpenSearch | loopback |
| — | NetBird mgmt/signal | no host port (tunnel) |
| 3478/udp | NetBird relay | **only if the opt-in relay is enabled** |
| 8632/tcp | Vibe Print gateway + admin UI | **mesh interface** |
| 443/tcp | Vaultwarden | **mesh interface** (the published path in mesh_only mode) |
| 3001/tcp | Uptime Kuma | **mesh interface** |
| 8085/tcp | ntfy | **mesh interface** |
| 8080/tcp | CrowdSec LAPI | loopback |
| 9392/tcp | Greenbone (opt) | loopback |

**No inbound ports from the internet.** The only possible exception is the
opt-in NetBird relay, and enabling it is a logged, QI-approved change recorded
in the risk assessment.

### Sharing a host with the Vibe Appliance

Both can run on one box, and `preflight/ports.sh` now checks for the collision
in both directions rather than assuming it away. Two things are worth knowing
before you try:

- **`:443` genuinely collides.** The appliance's Caddy binds `0.0.0.0:443`;
  Vaultwarden binds `<mesh-ip>:443` in `mesh_only` mode, and a wildcard bind
  wins over a specific one. Run Vaultwarden in **tunnel** mode on a shared
  host — which is what most firms should pick anyway — or give Sentinel its
  own box. Preflight now names the appliance as the owner instead of printing a
  pid.
- **Two Cloudflare Tunnels on one zone is fine.** Sentinel provisions its own
  tunnel and its own CNAMEs; the appliance provisions its own. The appliance's
  stale-CNAME pruning filters on records whose content matches **its own**
  tunnel id (`infra/cloudflared-up.sh` §5b), so it will not delete Sentinel's
  records — verified by reading that code, not assumed. The appliance's
  renderers also skip any manifest carrying `runtime: "sentinel"`, so it emits
  no vhost, no emergency frontend and no ingress rule for a Sentinel module.

The resource floors still apply and are the more common reason for a second
host: `core` alone wants 4 cores and 8 GB **free**, against the appliance's
1vcpu/2GB reference droplet.

---

## Preflight

Two rounds. The first needs nothing from the firm; the second needs the wizard
answers. Every check prints `PASS` or `FAIL` **with a plain-English reason**.

**Round A — host facts**

| Check | What it enforces |
|---|---|
| `os.sh` | Ubuntu 22.04/24.04 or Debian 12; jq, curl, openssl present |
| `docker.sh` | Docker ≥ 24 with Compose v2; user namespaces not remapped |
| `kernel.sh` | Kernel ≥ 5.8 with BTF for Falco's modern eBPF; falls back to privileged mode and **records a risk item** if absent |
| `sysctl.sh` | `vm.max_map_count >= 262144`, set persistently — OpenSearch will not start otherwise |
| `auditd.sh` | auditd installed and not fighting another audit consumer |
| `timesync.sh` | `systemd-timesyncd` or chrony active |

**Round B — firm inputs**

| Check | What it enforces |
|---|---|
| `resources.sh` | CPU, free RAM, and computed disk for the selected modules |
| `ports.sh` | Every port in the map above, including against other Vibe appliances |
| `dns.sh` | The domain resolves and the zone is Cloudflare-managed |
| `cloudflare.sh` | Each token scope, individually |
| `smtp.sh` | Sends a real test message |

---

## First-boot order

Enforced by the installer, with a health gate on every step:

```
Postgres/Redis → Authentik → certs sidecar (wildcard) → Sentinel API/web
→ Wazuh indexer → Wazuh manager → dashboard → ntfy → CrowdSec → Falco
→ mesh → keys → pulse → print → scan
```

The mesh step is the one that changes things underneath you: once NetBird is
up, the installer rebinds every mesh-only listener from `127.0.0.1` to the real
mesh IP, re-merges the compose, and corrects the DNS records. If the Sentinel
host is not itself a NetBird peer yet, mesh-bound services stay on loopback and
the installer says so — re-run after enrolling the host.

---

## Endpoint bundles (Sentinel Lite)

```bash
sudo bash lite/generate-lite.sh --platform all --role workstation
```

Produces per-firm Windows, macOS, and Linux bundles under
`/var/lib/vibe-sentinel/lite/<timestamp>/`. Each carries the Wazuh agent
config, Sysmon (or auditd rules, or EndpointSecurity), the posture collector on
a 4-hour schedule, the firm print queues, host firewall rules blocking
9100/631/515 except to the gateway, and a **one-time NetBird setup key**.

**NetBird is enrolled first, always.** Every Sentinel service binds the mesh
interface only, so an agent installed before the mesh is up looks enrolled and
reports nothing. Each bundle enforces the order and refuses to continue if the
mesh does not come up.

Bundles contain credentials. Move them over the mesh or on encrypted media,
never by email, and delete them when the batch is enrolled.

---

## Upgrading

```bash
git -C /opt/vibe-sentinel-installer fetch --tags
git -C /opt/vibe-sentinel-installer checkout v0.2.0
sudo bash /opt/vibe-sentinel-installer/upgrade/upgrade.sh 0.2.0 --dry-run
sudo bash /opt/vibe-sentinel-installer/upgrade/upgrade.sh 0.2.0
```

`--dry-run` prints the image diff and the gate result and changes nothing.

A real upgrade: diffs the deployed manifest → **checks the harness gate** →
takes a pre-upgrade snapshot (Vibe Vault if present, the built-in restic job if
not) → stops the stack → runs each module's `migrate/` steps → re-renders and
brings everything up in the §2.6 order → runs every module's healthcheck.

### The harness gate

`upgrade.sh` **refuses** to move Uptime Kuma, Vaultwarden, NetBird, Authentik,
or Wazuh to a version that `versions/manifest.json` does not mark
`harness_passed: true`. There is no `--force`.

These five are gated because a break in them is *silent*:

- **Uptime Kuma** — unversioned socket.io API; monitors quietly stop being
  managed and nothing looks wrong
- **Vaultwarden** — one-way schema migration over the firm's entire vault
- **NetBird** — every agent's only path home
- **Authentik** — the IdP the Sentinel UI depends on
- **Wazuh** — the detection engine; a broken decoder set reads as "quiet"

The way past the gate is to run the harness against the target version and cut
a tag whose manifest says so. Editing the manifest on the host defeats the only
thing standing between the firm and a silent monitoring outage.

---

## Uninstalling

```bash
sudo bash uninstall.sh                    # export first, then tear down
sudo bash uninstall.sh --keep-data        # containers only; volumes stay
sudo bash uninstall.sh --purge            # also remove /etc/vibe-sentinel
```

The **data export runs before anything is removed**: `pg_dump` of every
database, a tarball per volume, host state, config and secrets, and an
`EXPORT-MANIFEST.json` describing what is in there. Skipping it takes a typed
confirmation.

This matters more than it looks. Incident records, reports, attestations, and
evidence are the firm's compliance artifacts and are retained indefinitely
(§2.4) — several of them must outlive the tool by years.

Four things the uninstaller cannot reach, and tells you about at the end:
endpoint agents, Cloudflare DNS/tunnel/Access, the compensating controls the
firm now needs recorded, and the WISP that still names Sentinel as an
implemented safeguard.

---

## Layout

```
install.sh                 curl|bash entry point; wizard, preflight, first boot
uninstall.sh               data-export prompt, then per-module teardown
lib/                       common, cloudflare, compose-merge, health, secrets
preflight/                 11 checks, two rounds
wizard/                    firm profile → modules → secrets
modules/<id>/
  manifest.json            THE module's facts: host ports, resource floor, host
                           prerequisites, boot order, upgrade gate, ingress.
                           Read by this installer AND by the Vibe Appliance's
                           console, so a firm sees one catalog.
  compose.yml              services; images via ${IMG_*} from the manifest
  env.schema               KEY=description:required|optional
  healthcheck.sh           module probe; exit 0 = healthy
  uninstall.sh             teardown; honours REMOVE_VOLUMES
  migrate/                 versioned upgrade steps
.schema/                   the appliance's manifest schema, vendored; CI fails
                           on drift
scripts/check-manifests.py verifies every manifest still agrees with compose.yml,
                           versions/manifest.json and install.sh
lite/                      per-firm endpoint bundle generator
upgrade/upgrade.sh         snapshot → gate → migrate → restart → verify
versions/manifest.json     every image, tag, digest, and harness state
```

Modules are self-contained: each declares its own networks and volumes, and
Compose unions them at merge time. Cross-module ordering is enforced by the
installer's health gates, not `depends_on`, so any subset of modules is a valid
stack.

### Image pinning

Every image is referenced as `${IMG_*}`, resolved from
`versions/manifest.json`. The digests are currently
`sha256:TODO-pin-during-phase0` placeholders — `lib/secrets.sh` prefers a
digest and falls back to the tag while the placeholder is present, so the
appliance is installable today and immutable once **Phase 0** (the 60-day
Kisaes dogfood baseline) pins them. Until then an upstream retag can change
what runs on a firm's host, which is exactly the drift SENT-V-SENT-001 exists
to catch.

---

## What Sentinel is, and what it is not

It is a monitoring and evidence tool. It watches the controls, keeps the
records the Safeguards Rule asks for, and tells you when something changes.

It is not a guarantee, and it does not transfer responsibility. The firm
remains responsible for its own information security program. Nothing leaves
the premises by default.

## Licensing

PolyForm Internal Use 1.0.0 for a firm's own use — **included at no charge with
any licensed Vibe product**. The only paid tier is the MSP/multi-tenant
commercial license for firms or providers monitoring other firms.

Third-party components keep their own licenses (Wazuh GPLv2, Falco Apache-2.0,
CrowdSec MIT, OpenSearch Apache-2.0, Greenbone GPL, NetBird BSD-3, Authentik
MIT, Vaultwarden AGPL-3.0, Uptime Kuma MIT). See the third-party notices for
the full text and the Vaultwarden source offer.
