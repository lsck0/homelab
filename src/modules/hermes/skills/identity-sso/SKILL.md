---
name: identity-sso
description: Users, groups, passwords and 2FA (lldap, Authelia).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, Authelia, LDAP, SSO]
    related_skills: [homelab-ops]
---

# Identity

- lldap vm-102 (10.100.0.102): user/group store, UI https://lldap.lsck0.dev.
- Authelia vm-101 (10.100.0.101:9091): SSO portal https://auth.lsck0.dev,
  ForwardAuth for Traefik, OIDC for Forgejo/Nextcloud/Vaultwarden. Policy:
  two_factor for every *.lsck0.dev host.

## lldap via its GraphQL API (run on vm-102)

```
ssh 10.100.0.102 'TOKEN=$(curl -s -X POST localhost:17170/auth/simple/login -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$(cat /run/secrets/lldap-admin-password)\"}" | jq -r .token); \
  curl -s localhost:17170/api/graphql -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"query\":\"{ users { id email displayName groups { displayName } } }\"}"'
```
- Create user: mutation `createUser(user:{id:"name", email:"...", displayName:"..."})`.
- Add to group: `addUserToGroup(userId:"name", groupId:<int>)` (groups: `{ groups { id displayName } }`).
- Set password: `ssh 10.100.0.102 lldap_set_password --base-url http://localhost:17170 --admin-username admin --admin-password "$(cat /run/secrets/lldap-admin-password)" --username <user> --password <new>`.
  Send new passwords to the owner privately, never into a group chat.

## Authelia

- Logs: `ssh 10.100.0.101 journalctl -u authelia-main -n 100` (failed logins, bans).
- Reset a user's TOTP/WebAuthn: `ssh 10.100.0.101 authelia storage user totp delete <user> --config /etc/authelia/...`
  (find the config path with `systemctl cat authelia-main`).
- Regulation bans (too many failures) clear after the ban time or with `authelia storage` commands.
- One-time codes for device registration go to the filesystem notifier:
  `ssh 10.100.0.101 'cat /var/lib/authelia-main/notification.txt'`.
