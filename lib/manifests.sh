#!/usr/bin/env bash
# lib/manifests.sh — read modules/<id>/manifest.json.
#
# Every module's facts — the ports it publishes, the CPU and RAM it needs, the
# host prerequisites it depends on, where it sits in the boot order, which
# upgrade family gates it — live in ONE file per module. Before this they were
# copied into install.sh (boot order), preflight/ports.sh (port map),
# preflight/resources.sh (resource floor), README.md (the module table) and
# versions/manifest.json (images), and the copies had already drifted: the port
# map was missing 443 and 3001 entirely, and it still listed six print ports for
# services that no longer exist.
#
# The manifest conforms to the Vibe Appliance's per-app schema, vendored at
# .schema/manifest.schema.json and CI-checked for drift. That is what lets the
# appliance's console show Sentinel modules in the same catalog as Vibe apps
# without either side learning the other's internals — see
# docs/addenda/sentinel-federation.md in that repo.
#
# Idempotency: pure reads, no side effects.
# Reverse operation: none needed.
# shellcheck shell=bash

MANIFESTS_ROOT="${MANIFESTS_ROOT:-$INSTALLER_ROOT/modules}"

# manifest_path <module-id>
manifest_path() { printf '%s/%s/manifest.json' "$MANIFESTS_ROOT" "$1"; }

# manifest_field <module-id> <python expression over `data`>
# Prints nothing and returns 0 when the manifest is missing, so a caller can
# degrade to its own default rather than aborting the install.
manifest_field() {
  local f
  f="$(manifest_path "$1")"
  [ -f "$f" ] || return 0
  python3 - "$f" "$2" <<'PYEOF' 2>/dev/null || true
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
result = eval(sys.argv[2], {"data": data, "json": json})
if result is None:
    sys.exit(0)
print(result)
PYEOF
}

# manifest_ids — every module that ships a manifest, in bootOrder then id.
manifest_ids() {
  python3 - "$MANIFESTS_ROOT" <<'PYEOF' 2>/dev/null || true
import json, os, sys
root = sys.argv[1]
rows = []
try:
    ids = sorted(os.listdir(root))
except OSError:
    sys.exit(0)
for mid in ids:
    p = os.path.join(root, mid, "manifest.json")
    if not os.path.isfile(p):
        continue
    try:
        with open(p, encoding="utf-8") as fh:
            m = json.load(fh)
    except Exception:
        continue
    rows.append((m.get("bootOrder", 999), mid))
for _, mid in sorted(rows):
    print(mid)
PYEOF
}

# manifest_host_ports <module-id...>
# Emits "<port> <proto> <bind> <optional> <label>" per line for the modules
# named, in declaration order. A range emits its low port with the high port
# folded into the label, because every caller so far checks a listener rather
# than enumerating the range.
manifest_host_ports() {
  local mid
  for mid in "$@"; do
    manifest_field "$mid" 'chr(10).join(" ".join([str(p["port"]), p.get("proto","tcp"), p["bind"], "optional" if p.get("optional") else "required", (p.get("label","") + ("" if p.get("portEnd") is None else " (through %d)" % p["portEnd"]))]) for p in (data.get("hostPorts") or []))'
  done
}

# manifest_resources <module-id...>
# Prints "<tenths-of-a-core> <megabytes>" summed across the modules named.
manifest_resources() {
  local mid cpu10=0 mem=0 line c m
  for mid in "$@"; do
    line="$(manifest_field "$mid" '"%d %d" % (round(float((data.get("resources") or {}).get("cores", 0)) * 10), int((data.get("resources") or {}).get("ramMb", 0)))')"
    [ -n "$line" ] || continue
    c="${line%% *}"; m="${line##* }"
    cpu10=$((cpu10 + c)); mem=$((mem + m))
  done
  printf '%d %d' "$cpu10" "$mem"
}

# manifest_host_prereqs <module-id...> — deduplicated, one per line.
manifest_host_prereqs() {
  local mid
  for mid in "$@"; do
    manifest_field "$mid" 'chr(10).join(data.get("hostPrereqs") or [])'
  done | awk 'NF && !seen[$0]++'
}

# manifest_disable_requires <module-id> — non-empty when turning the module off
# needs a recorded compensating control before the appliance will proceed.
manifest_disable_requires() {
  manifest_field "$1" 'data.get("disableRequires","")'
}

# manifest_harness_family <module-id> — non-empty when the module's images are
# upgrade-gated on a harness run. upgrade/upgrade.sh is what enforces it.
manifest_harness_family() {
  manifest_field "$1" '(data.get("harnessGate") or {}).get("family","") if (data.get("harnessGate") or {}).get("gated", True) else ""'
}
