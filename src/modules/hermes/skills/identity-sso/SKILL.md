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

- lldap vm-102 (10.100.0.102): the only account store, UI https://lldap.lsck0.dev.
- Authelia vm-101 (10.100.0.101:9091): SSO portal https://auth.lsck0.dev,
  ForwardAuth for Traefik, OIDC for Forgejo, Nextcloud, Vaultwarden,
  Audiobookshelf and Kavita. Jellyfin binds to lldap directly (LDAP-Auth
  plugin) because its TV and phone apps cannot follow a portal redirect.
  Policy: `two_factor` everywhere, including the OIDC clients.

## Granting and revoking a service

Authorisation is lldap group membership. `src/modules/routes.nix` gives every
`auth = "sso"` route a `group`, and `101-internal-authelia.nix` turns that into
an allow rule plus a deny rule for the same host. So:

- **to take a service away from someone**, remove them from that route's group
  in the lldap UI. It takes effect within `refresh_interval` (1 minute).
- **to change which group guards a service**, edit `group` in routes.nix and
  deploy. lldap seeds every group the routes mention, and the owner is put in
  all of them, so a new group name cannot lock the owner out.
- groups in use today: `admins` (everything operational), `users` (the ordinary
  apps), `media` (Jellyseerr, Navidrome, qBittorrent, Suwayomi).
- a host with no entry in routes.nix falls through to the last rule, which
  requires `admins`. Adding a route without a `group` defaults it to `users`.

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
