#!/usr/bin/env bash
# renew proton's forwarded port, point the dnat set at it and hand it to qbittorrent
#
# Run by the router's protonvpn-port timer (instances/300-router/main.nix), which sets the environment:
#   PEER_HOST   the inbound vpn member, qbittorrent
#   GATEWAY     the provider's nat-pmp gateway inside the tunnel
#   LEASE_S     the lease asked for; the timer renews well inside it
set -euo pipefail

: "${PEER_HOST:?the inbound member address}" "${GATEWAY:?the provider gateway}" "${LEASE_S:?the lease in seconds}"
# qbittorrent's webui (112-internal-qbittorrent/instance.nix port)
API="http://$PEER_HOST:80/api/v2"
TABLE=proton-port
SET=proton_port
# proton's documented request: private port 1, public port 0 (the gateway picks it)
PRIVATE_PORT=1
PUBLIC_PORT=0

port=""
for proto in udp tcp; do
  out=$(natpmpc -g "$GATEWAY" -a "$PRIVATE_PORT" "$PUBLIC_PORT" "$proto" "$LEASE_S" 2>&1) || {
    echo "natpmpc failed for $proto: $out"
    exit 1
  }
  port=$(sed -n 's/.*Mapped public port \([0-9]\+\).*/\1/p' <<<"$out" | head -1)
  [ -n "$port" ] || { echo "no port in the $proto reply: $out"; exit 1; }
done

# dnat first, so the port leads somewhere before qbittorrent announces it
current=$(nft -j list set ip "$TABLE" "$SET" | jq -r '.nftables[] | .set? | select(.) | .elem[0] // empty' | head -1)
if [ "$current" != "$port" ]; then
  nft flush set ip "$TABLE" "$SET"
  nft add element ip "$TABLE" "$SET" "{ $port }"
  echo "forwarding $port to $PEER_HOST"
fi

# compare against the client's real port, not a note
have=$(curl -sf "$API/app/preferences" | sed -n 's/.*"listen_port":\([0-9]*\).*/\1/p')
if [ "$have" = "$port" ]; then
  exit 0
fi

if ! curl -sf -X POST "$API/app/setPreferences" \
    --data-urlencode "json={\"listen_port\":$port,\"random_port\":false,\"upnp\":false}" >/dev/null; then
  echo "could not give qBittorrent the new port $port"
  exit 1
fi
echo "qBittorrent is now on $port"
