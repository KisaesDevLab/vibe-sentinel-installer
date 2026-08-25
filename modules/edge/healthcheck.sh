#!/usr/bin/env bash
# modules/edge/healthcheck.sh
set -uo pipefail
ok=0
curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8080/health \
  && echo "OK   crowdsec LAPI (loopback :8080)" \
  || { echo "FAIL crowdsec LAPI"; ok=1; }
docker ps --format '{{.Names}}' | grep -q cs-firewall-bouncer \
  && echo "OK   cs-firewall-bouncer" \
  || { echo "FAIL cs-firewall-bouncer"; ok=1; }
exit "$ok"
