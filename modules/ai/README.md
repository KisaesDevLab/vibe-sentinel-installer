# ai — AI summarization (no container)

This module ships **no container**. It writes one file,
`/etc/vibe-sentinel/ai/router-client.json`, which tells `sentinel-api` and
`sentinel-worker` how to reach a model. `install.sh` runs `setup.sh` at the end
of the first-boot sequence; `upgrade/upgrade.sh` re-runs it after every
upgrade.

## What AI is used for

Prose only, over numbers that were already computed deterministically:

- daily digest and weekly summary
- the plain-English one-liner on an alert
- the narrative sections of the annual report

**If no model is reachable, nothing breaks.** Sentinel falls back to a
deterministic template. The counts, the timelines, and the evidence are
identical either way — only the wording changes. No alert, report, or
compliance artifact depends on a model being available.

## Modes

| Mode | Default | What it does | What leaves the premises |
|---|---|---|---|
| `local` | yes | vibellm (Ollama) through the Vibe AI Router | nothing |
| `cloud_optin` | no | Anthropic through the same router | alert/report **metadata only** |

Set with `.modules.ai.mode` in `/etc/vibe-sentinel/config.json`, or in the
wizard. The installer also mirrors it into `SENTINEL_AI_MODE` in `.env`.

## The metadata-only rule

This is the part worth reading twice. In `cloud_optin` mode, the payload is
restricted to:

`rule_id`, `rule_name`, `severity`, `count`, `asset_label`, `asset_class`,
`first_seen`, `last_seen`, `mitre_tags`, `req_tags`

and explicitly excludes:

`raw_event`, `log_line`, `command_line`, `file_path`, `file_content`,
`username`, `email`, `client_name`, `ssn`, `ein`, `ptin`, `efin`,
`ip_address`, `hostname`

An asset label is the firm's own name for a machine ("Front Desk PC"), not its
hostname or address. No customer information, no taxpayer data, and no event
content ever reaches a cloud provider. **Every cloud call is written to the
disclosure log**, which is what a §7216 review and REQ-014 ask to see.

Enabling cloud mode is a firm decision with a paper trail: record it in the
risk assessment, and expect it to appear in the service-provider register.

## Why the router

Sentinel never calls a model provider directly. All traffic goes through the
Vibe AI Router, which is the single egress point and the single place calls are
logged. That is what makes "every call is in the disclosure log" enforceable
rather than aspirational, and it is why the egress allow-list in §2.2 names the
router rather than a provider.

## Files

| Path | What |
|---|---|
| `setup.sh` | Renders the client config from `config.json`; idempotent |
| `env.schema` | The one env key (`SENTINEL_AI_MODE`) |
| `/etc/vibe-sentinel/ai/router-client.json` | Generated; mode 640 |
| `/etc/vibe-sentinel/secrets/anthropic_api_key` | Cloud mode only; mode 600, operator-supplied |

## Enabling cloud mode

```bash
# 1. Record the decision
jq '.modules.ai.mode = "cloud_optin"' /etc/vibe-sentinel/config.json > /tmp/c \
  && install -m 600 /tmp/c /etc/vibe-sentinel/config.json && rm /tmp/c

# 2. Supply the key as a file-backed secret (never inline in a config)
install -m 600 /dev/stdin /etc/vibe-sentinel/secrets/anthropic_api_key <<<'sk-ant-...'

# 3. Re-render
bash /etc/vibe-sentinel/modules/ai/setup.sh
```

Turning it back off is step 1 with `"local"`, then step 3. No restart of the
stack is required — the config is read per call.
