#!/bin/bash
# Generate a one-time Authentik recovery link for akadmin (or a specified user).
set -euo pipefail

USER="${1:-akadmin}"
DAYS="${2:-10}"
VM_IP="10.100.0.101"

echo ">>> Generating Authentik recovery link for '$USER' (valid ${DAYS} days)..."

ssh -o StrictHostKeyChecking=accept-new "root@$VM_IP" \
  "docker exec authentik-worker-1 ak create_recovery_key $DAYS $USER" 2>/dev/null \
  | grep -o '/recovery/use-token/[^[:space:]]*' \
  | while read -r path; do
      echo ""
      echo "Recovery URL:"
      echo "  https://auth.lsck0.dev${path}"
      echo ""
      echo "Open this link in your browser to log in as '$USER'."
      echo "Link expires in ${DAYS} days. Treat it like a password."
    done
