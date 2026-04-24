#!/usr/bin/env bash
# Split DNS setup for homelab
# Routes *.lsck0.dev queries to the homelab router (CoreDNS)
# Everything else uses default DNS
#
# Requires: NetworkManager + dnsmasq
# Usage: sudo ./setup-dns.sh

set -euo pipefail

ROUTER_IP="192.168.178.29"
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
server=/${DOMAIN}/${ROUTER_IP}
EOF

systemctl restart NetworkManager

echo "Split DNS configured: *.${DOMAIN} → ${ROUTER_IP}"
echo "Verifying..."
host homepage.${DOMAIN} 2>/dev/null && echo "OK" || echo "FAIL - is ${ROUTER_IP} reachable?"
