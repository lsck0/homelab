#!/usr/bin/env bash
# Split DNS setup for homelab Routes *.lsck0.dev queries to the homelab router (CoreDNS)

set -euo pipefail

ROUTER_IP="192.168.178.29"
ROUTER_DNS_PORT="53"  # CoreDNS on the router (5353 is avahi)
DOMAIN="lsck0.dev"

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

cat > /etc/NetworkManager/dnsmasq.d/${DOMAIN//./-}.conf << EOF
server=/${DOMAIN}/${ROUTER_IP}#${ROUTER_DNS_PORT}
EOF

systemctl restart NetworkManager

echo "Split DNS configured: *.${DOMAIN} -> ${ROUTER_IP}:${ROUTER_DNS_PORT}"
echo "Verifying..."
dig +short homepage.${DOMAIN} @${ROUTER_IP} -p ${ROUTER_DNS_PORT} 2>/dev/null | grep -q "10.100.0.100" && echo "OK" || echo "FAIL - is ${ROUTER_IP}:${ROUTER_DNS_PORT} reachable?"
