#!/usr/bin/env bash
# Trust the homelab CA certificate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CA_CERT="$REPO_ROOT/secrets/homelab-ca.pem"

if [ ! -f "$CA_CERT" ]; then
  echo "ERROR: CA certificate not found at $CA_CERT" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo" >&2
  exit 1
fi

echo "Installing homelab CA certificate..."

# Detect OS and install accordingly
if [ -d /etc/ca-certificates/trust-source/anchors ]; then
  # Debian/Ubuntu/Arch
  cp "$CA_CERT" /etc/ca-certificates/trust-source/anchors/homelab-ca.crt
  update-ca-trust
  echo "✓ CA certificate installed and trusted (update-ca-trust)"
elif [ -d /etc/pki/ca-trust/source/anchors ]; then
  # RedHat/Fedora/CentOS
  cp "$CA_CERT" /etc/pki/ca-trust/source/anchors/homelab-ca.crt
  update-ca-trust
  echo "✓ CA certificate installed and trusted (update-ca-trust)"
else
  echo "ERROR: Unsupported system. Cannot find certificate trust directory." >&2
  exit 1
fi

echo ""
echo "You can now access internal services without SSL warnings:"
echo "  curl https://homepage.lsck0.dev/"
echo "  curl https://git.lsck0.dev/"
echo "  etc."
