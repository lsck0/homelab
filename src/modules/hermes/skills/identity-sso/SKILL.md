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

- lldap on vm-101 (10.100.0.101, beside Authelia): the only account store, UI https://lldap.lsck0.dev.
- Authelia vm-101 (10.100.0.101:9091): SSO portal https://auth.lsck0.dev,
  ForwardAuth for Traefik, OIDC for Forgejo, Jellyfin, Headplane and
  Home Assistant. Jellyfin binds to lldap directly (LDAP-Auth
  plugin) because its TV and phone apps cannot follow a portal redirect.
  Policy: `two_factor` everywhere, including the OIDC clients.

## Granting and revoking a service

Authorisation is lldap group membership. Routes in `src/modules/routes.nix` carry no
group field: `101-internal-authelia.nix` derives `app-<route name>` (the attribute name,
e.g. `app-homepage` for homelab.lsck0.dev) for every sso route (no `auth`, or
`auth = "sso"`) and turns it into an allow rule for `admins` and that group plus a deny
rule for the same host. OIDC clients check `app-<client id>` the same way. So:

- **to take a service away from someone**, remove them from that route's group
  in the lldap UI. It takes effect within `refresh_interval` (1 minute).
- groups: `admins` reach every page and are also put in lldap's built-in
  `lldap_admin`; everyone else gets one `app-<route>` group per page (e.g.
  `app-grafana`). There are no bundle groups. lldap seeds an `app-<route>`
  group for every sso and own-login route in routes.nix.
- a host with no entry in routes.nix falls through to the last rule, which
  requires `admins`.

## lldap via its GraphQL API (run on vm-101)

```
ssh 10.100.0.101 'TOKEN=$(curl -s -X POST localhost:17170/auth/simple/login -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$(cat /run/secrets/lldap-admin-password)\"}" | jq -r .token); \
  curl -s localhost:17170/api/graphql -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"query\":\"{ users { id email displayName groups { displayName } } }\"}"'
```
- Create user: mutation `createUser(user:{id:"name", email:"...", displayName:"..."})`.
- Add to group: `addUserToGroup(userId:"name", groupId:<int>)` (groups: `{ groups { id displayName } }`).
- Set password: `ssh 10.100.0.101 lldap_set_password --base-url http://localhost:17170 --admin-username admin --admin-password "$(cat /run/secrets/lldap-admin-password)" --username <user> --password <new>`.
  Send new passwords to the owner privately, never into a group chat.

## Authelia

- Logs: `ssh 10.100.0.101 journalctl -u authelia-main -n 100` (failed logins, bans).
- Reset a user's TOTP/WebAuthn: `ssh 10.100.0.101 authelia storage user totp delete <user> --config /etc/authelia/...`
  (find the config path with `systemctl cat authelia-main`).
- Regulation bans (too many failures) clear after the ban time or with `authelia storage` commands.
- One-time codes for device registration go to the filesystem notifier:
  `ssh 10.100.0.101 'cat /var/lib/authelia-main/notification.txt'`.
