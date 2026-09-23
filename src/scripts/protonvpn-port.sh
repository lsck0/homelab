#!/usr/bin/env bash
# Renew Proton's forwarded port, point the DNAT at it, and tell qBittorrent.
#
# Proton hands out a port over NAT-PMP with a 60-second lease and no way to
# ask for a particular one, so the port changes whenever the lease lapses or
# the tunnel reconnects. Without this the client is reachable for a minute
# and "firewalled" from then on, which halves the swarm and is what trackers
# count against you.
#
# Runs on the router, not on the torrent VM. The tunnel moved here when the
# egress classes (modules/egress.nix) took over from the per-VM tunnel in
# modules/vpn.nix, and the lease belongs wherever the tunnel is. One tunnel
# gets one port, so there is exactly one VM this can be given to.
#
# Three things have to agree, and the port is useless unless all three do:
#   1. Proton forwards <port> to this tunnel        (natpmpc, below)
#   2. the router forwards <port> on to the VM      (the nftables set)
#   3. qBittorrent binds and announces <port>       (the API call)
#
# Runs every 45 seconds: the lease is 60, and a renewal that lands late is the
# same as no renewal at all.
set -euo pipefail

GATEWAY=${GATEWAY:-10.2.0.1}
PEER_HOST=${PEER_HOST:-10.100.0.112}
# qBittorrent's WebUI. The router is on its bypass_auth_subnet_whitelist, so
# this needs no login. It used to run on the VM itself and go through
# `podman exec` because the VM's own address was not whitelisted; from here a
# plain request is the whole of it.
API=${API:-http://$PEER_HOST:80/api/v2}
TABLE=${TABLE:-proton-port}
SET=${SET:-proton_port}

# -a <private> <public> <proto> <lifetime>. 0 as the public port means "any",
# which is the only thing Proton offers; the reply carries what was given.
lease() {
  natpmpc -g "$GATEWAY" -a 1 0 "$1" 60 2>&1
}

port=""
for proto in udp tcp; do
  out=$(lease "$proto") || { echo "natpmpc failed for $proto: $out"; exit 1; }
  got=$(echo "$out" | sed -n 's/.*Mapped public port \([0-9]\+\).*/\1/p' | head -1)
  [ -n "$got" ] || { echo "no port in the $proto reply: $out"; exit 1; }
  port=$got
done

# The DNAT first. Doing this before the client is told means the forward is
# already in place for the port it is about to start announcing; the other
# order leaves a window where peers are told a port that lands nowhere.
#
# Replacing the set's contents rather than the rule: the rule matches @set and
# never changes, so there is no moment when no rule exists.
current_element=$(nft -j list set ip "$TABLE" "$SET" 2>/dev/null \
  | sed -n 's/.*"val":\([0-9]\+\).*/\1/p' | head -1)
if [ "$current_element" != "$port" ]; then
  nft flush set ip "$TABLE" "$SET"
  nft add element ip "$TABLE" "$SET" "{ $port }"
  echo "forwarding $port to $PEER_HOST"
fi

# Compare against what the client actually has, not against a note this script
# left itself. The cached value said "unchanged" while qBittorrent had been
# put back on 6881 by its own settings unit, so the lease was renewed every 45
# seconds and never applied. This runs ~1900 times a day and setPreferences
# makes the client rebind, so it still only fires when the two disagree.
have=$(curl -sf "$API/app/preferences" \
  | sed -n 's/.*"listen_port":\([0-9]*\).*/\1/p')
if [ "$have" = "$port" ]; then
  exit 0
fi

if curl -sf -X POST "$API/app/setPreferences" \
    --data-urlencode "json={\"listen_port\":$port,\"random_port\":false,\"upnp\":false}" >/dev/null; then
  echo "qBittorrent is now on $port"
else
  echo "could not give qBittorrent the new port $port"
  exit 1
fi
