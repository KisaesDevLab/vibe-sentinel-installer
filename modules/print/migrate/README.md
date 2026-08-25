# print — migrations

Versioned migration steps for the Vibe Print module live here as
`NNN-description.sh`, executed in order by `upgrade/upgrade.sh` when moving
between tagged releases. Each step must be idempotent and must not assume the
stack is running (the upgrade runs them between `down` and `up`).

Vibe Print is maintained as both a standalone product and a Sentinel module
from the **same image** (Decision 22). A migration step here must therefore
never assume Sentinel is present — the Sentinel integration layer (mesh
identity, inventory sync, event forwarding, policy push) is additive.

Covers:

- The `vibe_print` database on the shared Sentinel Postgres instance: queues,
  release policy per queue, held-job records, printer inventory, PINs.
- CUPS configuration in the `print-cups-config` volume — queue definitions,
  IPP Everywhere publishing, and the wildcard-cert paths. A CUPS major-version
  bump can rewrite `printers.conf`; the step must re-assert every queue's
  `release_mode` afterwards.
- Release-policy continuity. `direct_onsite_hold_offsite` is the default
  (Decision 26) and any queue the firm flipped to `always_hold` or
  `always_direct` must survive the upgrade unchanged — a queue that silently
  reverts to direct release would put client documents in an unattended tray.
- `ONSITE_SUBNETS` re-validation against the Sentinel host's own interfaces
  after a network change.
- Printer-isolation rules: re-run `printer-network-policy.sh` after any step
  that touches interfaces or the NetBird routing setup.

## Spool safety

The spool holds rendered client documents. Any step that moves or reformats
`/var/spool/vibe-print` must secure-delete the old copy, never leave a second
copy behind, and must not read job content (Decision 24 — no content
inspection, at any point in the pipeline, including migrations).

## Pre-upgrade checklist for this module

1. Drain held jobs, or accept that jobs past `HOLD_TIME_HOURS` will be
   secure-deleted during the window.
2. A Vault (or built-in restic) snapshot tagged `vibe-print` exists, covering
   the `vibe_print` database and the CUPS config volume.
3. The Print Audit Log reconciles to the CUPS job count before the upgrade, so
   any post-upgrade discrepancy is attributable.
