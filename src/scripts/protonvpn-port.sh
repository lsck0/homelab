#!/usr/bin/env bash
# Renew Proton's forwarded port and tell qBittorrent what it is.
#
# Proton hands out a port over NAT-PMP with a 60-second lease and no way to
# ask for a particular one, so the port changes whenever the lease lapses or
# the tunnel reconnects. Without this the client is reachable for a minute
# and "firewalled" from then on, which halves the swarm and is what trackers
# count against you.
#
# Runs every 45 seconds: the lease is 60, and a renewal that lands late is the
# same as no renewal at all.
set -euo pipefail

GATEWAY=${GATEWAY:-10.2.0.1}
QBIT=${QBIT:-http://127.0.0.1:80}
STATE=${STATE:-/var/lib/protonvpn/port}

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

mkdir -p "$(dirname "$STATE")"
# Only talk to qBittorrent when the port actually moved. This runs 1900 times
# a day and setPreferences makes the client rebind its listener.
if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$port" ]; then
  exit 0
fi

# 127.0.0.1 is on qBittorrent's API whitelist via the container's published
# port, so no login is needed.
if curl -sf -X POST "$QBIT/api/v2/app/setPreferences" \
    --data-urlencode "json={\"listen_port\":$port,\"random_port\":false,\"upnp\":false}" >/dev/null; then
  printf '%s' "$port" > "$STATE"
  echo "forwarded port is now $port"
else
  echo "could not give qBittorrent the new port $port"
  exit 1
fi
