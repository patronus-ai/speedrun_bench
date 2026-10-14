#!/bin/bash
# Block agent containers from reaching services on the HOST. Idempotent; re-run after a reboot
# or after the agentnet network is recreated (its bridge interface name follows the network id).
#
#   sudo bash scripts/firewall_agentnet.sh            # apply
#   sudo bash scripts/firewall_agentnet.sh --remove   # undo
#
# WHY. agentnet is `internal: true`, which stops routing to the internet but NOT traffic to the
# host itself: that arrives on the bridge and is handled by INPUT, not FORWARD, so Docker's
# DOCKER-USER chain never sees it. Without this, an agent can reach anything listening on the host
# -- other scorers, inference servers or shims holding API keys, game dev servers -- and a ban that
# looks airtight inside the compose files can be bypassed from the host side.
#
# WHAT STAYS OPEN. Only the host-side Gemini schema proxy (tools/gemini_schema_proxy.py, :8790),
# which the Gemini arms use as their inference endpoint, plus replies to connections the host
# opened. Model traffic goes out through the `proxy` container, not the host, and is unaffected.
set -euo pipefail

NET="${AGENTNET:-speedrun-bench_agentnet}"
ALLOW_TCP="${AGENTNET_HOST_ALLOW_TCP:-8790}"
CHAIN=AGENTNET-HOST

NID=$(docker network inspect "$NET" --format '{{.Id}}')
IFACE="br-${NID:0:12}"
ip link show "$IFACE" >/dev/null

for IPT in iptables ip6tables; do
  # Unhook and flush any previous version first, so re-running never stacks duplicate rules.
  while $IPT -D INPUT -i "$IFACE" -j "$CHAIN" 2>/dev/null; do :; done
  $IPT -F "$CHAIN" 2>/dev/null || true
  $IPT -X "$CHAIN" 2>/dev/null || true
  [ "${1:-}" = "--remove" ] && continue

  $IPT -N "$CHAIN"
  $IPT -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  if [ "$IPT" = iptables ]; then
    for p in $ALLOW_TCP; do $IPT -A "$CHAIN" -p tcp --dport "$p" -j RETURN; done
  fi
  $IPT -A "$CHAIN" -j DROP
  $IPT -I INPUT 1 -i "$IFACE" -j "$CHAIN"
done

if [ "${1:-}" = "--remove" ]; then
  echo "removed $CHAIN from $IFACE"
else
  echo "applied $CHAIN on $IFACE ($NET): host reachable from agentnet only on tcp/${ALLOW_TCP// /,}"
fi
