#!/usr/bin/env python3
"""Verify modules/<id>/manifest.json against the rest of the installer.

A manifest is only a single source of truth while something checks it still
describes reality. This is that something, and it runs in CI.

  1. every module ships a manifest, and every manifest names a real module
  2. the vendored schema has not drifted from the appliance's
  3. each manifest satisfies the schema's shape (dependency-free subset, plus
     full jsonschema validation when the library happens to be installed)
  4. hostPorts match the ports the module's compose.yml actually publishes
  5. harnessGate families exist in versions/manifest.json and agree with its
     gated_families list
  6. bootOrder agrees with the order install.sh brings modules up
  7. images referenced by versions/manifest.json's used_by cover every module

Exit 0 when everything agrees; 1 with a named reason otherwise.
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = os.path.join(ROOT, 'modules')
problems: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)


def load(path):
    with open(path, encoding='utf-8') as fh:
        return json.load(fh)


# --- 1. one manifest per module -------------------------------------------
module_ids = sorted(d for d in os.listdir(MODULES)
                    if os.path.isdir(os.path.join(MODULES, d)))
manifests = {}
for mid in module_ids:
    p = os.path.join(MODULES, mid, 'manifest.json')
    if not os.path.isfile(p):
        fail('modules/%s has no manifest.json' % mid)
        continue
    try:
        manifests[mid] = load(p)
    except Exception as exc:                                # noqa: BLE001
        fail('modules/%s/manifest.json is not valid JSON: %s' % (mid, exc))

# --- 2. vendored schema drift ---------------------------------------------
SCHEMA = os.path.join(ROOT, '.schema', 'manifest.schema.json')
schema = None
if not os.path.isfile(SCHEMA):
    fail('.schema/manifest.schema.json is missing - it is the contract this '
         'repo shares with the Vibe Appliance console')
else:
    schema = load(SCHEMA)
    upstream = os.environ.get('VIBE_APPLIANCE_SCHEMA')
    if upstream and os.path.isfile(upstream):
        if load(upstream) != schema:
            fail('.schema/manifest.schema.json has drifted from %s - re-vendor '
                 'it and re-check every manifest against the new shape' % upstream)

# --- 3. schema shape -------------------------------------------------------
if schema:
    try:
        import jsonschema                                    # noqa: PLC0415
        validator = jsonschema.Draft202012Validator(schema)
    except ImportError:
        validator = None
    for mid, m in manifests.items():
        if validator is not None:
            for err in validator.iter_errors(m):
                fail('modules/%s: %s -> %s'
                     % (mid, '/'.join(map(str, err.path)) or '(root)', err.message))
        else:
            for key in ('schemaVersion', 'slug', 'displayName', 'description'):
                if key not in m:
                    fail('modules/%s: missing required field %r' % (mid, key))
            if m.get('runtime') != 'sentinel':
                fail('modules/%s: runtime must be "sentinel"; the appliance '
                     'refuses to install anything it does not own' % mid)

# --- 4. hostPorts vs compose.yml ------------------------------------------
QUOTED = re.compile(r'-\s*"([^"]+)"')


def published_host_ports(line):
    """Host ports a compose short-syntax `ports:` entry publishes.

    The forms are `CONTAINER`, `HOST:CONTAINER` and `IP:HOST:CONTAINER`, with
    an optional `/proto`, and HOST may be a range or a ${VAR}. Split on colons
    and take the second-from-last field rather than pattern-matching the whole
    thing: a regex over the raw string backtracked into the middle of
    "3478:3478/udp" and reported a published port 8.
    """
    hit = QUOTED.search(line)
    if not hit:
        return []
    spec = hit.group(1).split('/')[0]
    parts = spec.split(':')
    if len(parts) < 2:
        return []                      # container-only: nothing published
    host = parts[-2]
    if not host or host.startswith('$'):
        return []
    lo, _, hi = host.partition('-')
    if not lo.isdigit():
        return []
    return [int(lo)] if not hi.isdigit() else list(range(int(lo), int(hi) + 1))


for mid, m in manifests.items():
    compose = os.path.join(MODULES, mid, 'compose.yml')
    declared = {p['port'] for p in (m.get('hostPorts') or [])}
    if not os.path.isfile(compose):
        if declared:
            fail('modules/%s declares hostPorts but ships no compose.yml' % mid)
        continue
    with open(compose, encoding='utf-8') as fh:
        body = fh.read()
    published = set()
    sources = [body]
    # The relay sub-module lives beside mesh and is merged only when enabled;
    # its port is still a host publish and still needs declaring.
    relay = os.path.join(MODULES, mid, 'relay', 'compose.yml')
    if os.path.isfile(relay):
        with open(relay, encoding='utf-8') as fh:
            sources.append(fh.read())
    for source in sources:
        in_ports = False
        for line in source.splitlines():
            stripped = line.strip()
            if stripped.startswith('#'):
                continue
            if stripped.startswith('ports:'):
                in_ports = True
                continue
            if in_ports and not stripped.startswith('-'):
                in_ports = False
            if in_ports:
                published.update(published_host_ports(stripped))
    for extra in sorted(published - declared):
        fail('modules/%s publishes host port %d in compose.yml but does not '
             'declare it in manifest.json hostPorts - a conflict on it would '
             'go undetected' % (mid, extra))
    for missing in sorted(declared - published):
        fail('modules/%s declares host port %d in manifest.json but no compose '
             'service publishes it - preflight would check a port nothing binds'
             % (mid, missing))

# --- 5 & 7. images and harness gating -------------------------------------
VERSIONS = os.path.join(ROOT, 'versions', 'manifest.json')
if not os.path.isfile(VERSIONS):
    fail('versions/manifest.json is missing')
else:
    versions = load(VERSIONS)
    gated = set(versions.get('harness_gating', {}).get('gated_families', []))
    images = versions.get('images', {})
    used_by = {}
    for key, img in images.items():
        for consumer in img.get('used_by', []):
            used_by.setdefault(consumer.split('/')[0], []).append(key)

    for mid, m in manifests.items():
        family = (m.get('harnessGate') or {}).get('family')
        if not family:
            # No gate declared: make sure the module does not in fact own a
            # gated image, which would mean the gate is silently unclaimed.
            owned = used_by.get(mid, [])
            unclaimed = [k for k in owned if images[k].get('harness_gated')]
            if unclaimed:
                fail('modules/%s owns harness-gated image(s) %s but declares no '
                     'harnessGate - the console would show it as ungated'
                     % (mid, ', '.join(sorted(unclaimed))))
            continue
        if family not in gated:
            fail('modules/%s declares harnessGate.family %r, which is not in '
                 "versions/manifest.json harness_gating.gated_families"
                 % (mid, family))
        if not any(family in key for key in used_by.get(mid, [])):
            fail('modules/%s declares harnessGate.family %r but owns no image '
                 'whose key contains it' % (mid, family))

    for mid in manifests:
        if mid not in used_by and mid != 'ai':
            fail('modules/%s owns no image in versions/manifest.json; only the '
                 'ai module legitimately ships no container' % mid)

# --- 6. bootOrder vs install.sh -------------------------------------------
INSTALL = os.path.join(ROOT, 'install.sh')
if os.path.isfile(INSTALL):
    with open(INSTALL, encoding='utf-8') as fh:
        install = fh.read()
    seen, sequence = set(), []
    for hit in re.finditer(r'module_selected\s+([a-z]+)', install):
        mid = hit.group(1)
        if mid not in seen:
            seen.add(mid)
            sequence.append(mid)
    # core is unconditional and always first.
    sequence = ['core'] + [m for m in sequence if m in manifests and m != 'core']
    orders = [(mid, manifests[mid].get('bootOrder')) for mid in sequence
              if mid in manifests]
    for (a, oa), (b, ob) in zip(orders, orders[1:]):
        if oa is None or ob is None:
            fail('modules/%s or modules/%s has no bootOrder' % (a, b))
        elif oa >= ob:
            fail('install.sh starts %s before %s, but their bootOrder says the '
                 'opposite (%s=%s, %s=%s)' % (a, b, a, oa, b, ob))

for line in problems:
    print('FAIL ' + line)
if problems:
    print('\n%d inconsistency/ies between the manifests and the installer.'
          % len(problems))
    sys.exit(1)
print('OK   %d module manifests agree with compose, versions and install.sh'
      % len(manifests))
