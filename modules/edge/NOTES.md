# edge — Cloudflare bouncer deployment note

The Cloudflare half of the edge module is **not a container**. The legacy
CrowdSec Cloudflare IP-list bouncer is deprecated; the current bouncer is
**Workers-based** (Decision R22, plan Phase 5). It is deployed by
`cloudflare-worker-bouncer.sh`, which:

1. registers a bouncer API key against the local CrowdSec LAPI
   (`cscli bouncers add cloudflare-worker`),
2. uploads the Worker script into the **firm's own** Cloudflare account via
   the API, and
3. adds Worker routes on the tunnel-published hostnames
   (`sentinel.`, `id.`, `nb.`, `nb-signal.`, `vault.`).

Requirements beyond the §2.6 token scopes: **Account → Workers Scripts →
Edit** on the same API token. The preflight does not hard-require this scope
because the local nftables bouncer provides blocking regardless; if the
Worker deploy fails, install.sh logs a warning and continues.

The Worker script body in this repo is a **pass-through placeholder**; the
pinned upstream `cs-cloudflare-worker-bouncer` build replaces it in Phase 5
after Phase 0 verifies the pinned version. The placeholder never blocks
traffic, so a partial deploy cannot lock a firm out of its own dashboards.

CrowdSec decisions still reach Cloudflare's edge in the meantime through the
Worker's LAPI polling once the real script lands; local nftables enforcement
(cs-firewall-bouncer, host network) is active from first boot either way.
