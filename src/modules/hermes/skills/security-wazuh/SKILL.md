---
name: security-wazuh
description: Security events: Wazuh, CrowdSec, SSH and audits.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Security, Wazuh, SIEM]
    related_skills: [homelab-ops]
---

# Security

## Wazuh (vm-108, dashboard https://wazuh.lsck0.dev)

Every VM forwards its journal via syslog to the Wazuh manager (UDP 514); rules
flag SSH brute force, sudo/root events, service failures and known attack
patterns.

- Stack status: `ssh 10.100.0.108 'docker ps; systemctl status wazuh'`
- Recent alerts: `ssh 10.100.0.108 'docker exec single-node-wazuh.manager-1 tail -n 50 /var/ossec/logs/alerts/alerts.json' | jq -c '{time:.timestamp, level:.rule.level, desc:.rule.description, host:.predecoder.hostname}'`
- High-level only: filter `.rule.level >= 10`.
- Indexer query (last 24 h, level ≥ 10): `ssh 10.100.0.108 "curl -sk -u admin:\$(cat /var/lib/wazuh/admin-pass) https://localhost:9200/wazuh-alerts-*/_search -H 'Content-Type: application/json' -d '{\"size\":20,\"sort\":[{\"timestamp\":\"desc\"}],\"query\":{\"range\":{\"rule.level\":{\"gte\":10}}}}'"`
- Service health: `ssh 10.100.0.108 docker logs --tail 50 single-node-wazuh.manager-1`.

## Also check

- CrowdSec bans/alerts on vm-200 (see `traefik-ingress`).
- SSH logins: `ssh <ip> journalctl -u sshd --since -24h | grep -E 'Accepted|Failed'`.
- Authelia failed logins (see `identity-sso`).
- Open ports on a VM: `ssh <ip> ss -ltnp`.

When something looks like a real intrusion: tell the owner immediately with the
evidence, snapshot the VM (`qm snapshot`), do not delete logs.
