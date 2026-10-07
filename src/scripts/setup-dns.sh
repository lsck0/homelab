#!/usr/bin/env bash
# split dns on the workstation: NetworkManager's dnsmasq sends *.<domain> to the router's coredns
#
# The lab's facts come from src/generated/lab.json (the desktop clients' interface, written by sync.sh) and the
# router's lan address from src/generated/site.json.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=src/scripts/lib/tools.sh
. "$SRC/scripts/lib/tools.sh"
tools_require jq

LAB_EXPORT="$SRC/generated/lab.json"
ROUTER_IP=$(jq -r .lan.router "$SRC/generated/site.json")
# coredns; 5353 on the router is avahi
ROUTER_DNS_PORT=53
DOMAIN=$(jq -r .domain "$LAB_EXPORT")
# an internal route the split horizon answers with the internal ingress
PROBE_NAME=$(jq -r .routes.homepage.host "$LAB_EXPORT")
PROBE_ANSWER=$(jq -r '.guests[.zones.internal.ingress | tostring].ip' "$LAB_EXPORT")

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo" >&2
  exit 1
fi

if ! systemctl is-active --quiet NetworkManager; then
  echo "ERROR: NetworkManager is not running. This script requires NetworkManager with dnsmasq." >&2
  exit 1
fi

echo "WARNING: This will restart NetworkManager, which briefly drops all connections."
echo "If running over SSH through the managed interface, you may lose your session."

mkdir -p /etc/NetworkManager/conf.d /etc/NetworkManager/dnsmasq.d

cat > /etc/NetworkManager/conf.d/dns.conf << EOF
[main]
dns=dnsmasq
EOF

cat > "/etc/NetworkManager/dnsmasq.d/${DOMAIN//./-}.conf" << EOF
server=/${DOMAIN}/${ROUTER_IP}#${ROUTER_DNS_PORT}
EOF

systemctl restart NetworkManager

echo "Split DNS configured: *.${DOMAIN} -> ${ROUTER_IP}:${ROUTER_DNS_PORT}"
echo "Verifying..."
if dig +short "$PROBE_NAME" "@$ROUTER_IP" -p "$ROUTER_DNS_PORT" 2>/dev/null | grep -x "$PROBE_ANSWER" >/dev/null; then
  echo "OK"
else
  echo "FAIL: is ${ROUTER_IP}:${ROUTER_DNS_PORT} reachable?"
fi
