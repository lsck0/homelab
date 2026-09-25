#!/usr/bin/env bash
# Renew Proton's forwarded port, point the DNAT at it, and tell qBittorrent.
set -euo pipefail

GATEWAY=${GATEWAY:-10.2.0.1}
PEER_HOST=${PEER_HOST:-10.100.0.112}
# qBittorrent's WebUI.
API=${API:-http://$PEER_HOST:80/api/v2}
TABLE=${TABLE:-proton-port}
SET=${SET:-proton_port}

# -a <private> <public> <proto> <lifetime>.
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

# The DNAT first.
current_element=$(nft -j list set ip "$TABLE" "$SET" 2>/dev/null \
  | sed -n 's/.*"val":\([0-9]\+\).*/\1/p' | head -1)
if [ "$current_element" != "$port" ]; then
  nft flush set ip "$TABLE" "$SET"
  nft add element ip "$TABLE" "$SET" "{ $port }"
  echo "forwarding $port to $PEER_HOST"
fi

# Compare against what the client actually has, not against a note this script left itself.
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
