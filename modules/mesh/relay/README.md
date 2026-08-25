# mesh/relay — opt-in only

**Default: OFF. Sentinel ships direct-only with zero inbound ports**
(Decision 17, plan §2.2).

Enable the relay **only after BOTH**:

1. an enrolling peer **failed the NAT reachability test** (it could not
   establish a direct WireGuard connection), and
2. the **QI consented** to opening one UDP port (3478).

Enabling the relay is a **logged, QI-approved change**: it is recorded in the
change log and the risk assessment, watched by CrowdSec, and becomes the
single approved exception for SENT-E-005 (exposed-port detection — the
expected WAN port set is otherwise empty). Firms that refuse any inbound
exposure should use the Tailscale connector instead.

To enable (after the two conditions above are met and documented):

```sh
jq '.modules.mesh.relay_enabled = true
    | .modules.mesh.relay_qi_approved_at = (now | todate)' \
   /etc/vibe-sentinel/config.json > /tmp/cfg && \
   install -m 600 /tmp/cfg /etc/vibe-sentinel/config.json
bash /opt/vibe-sentinel-installer/install.sh   # re-run; merges relay compose
```

The re-run regenerates the merged compose with `relay/compose.yml`, opens
3478/udp, and re-checks the port map preflight.
