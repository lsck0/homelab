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
  ForwardAuth for Traefik, OIDC for Forgejo, Jellyfin, Headplane, Headscale and
  Home Assistant. Jellyfin is OIDC only; its apps log in with Quick Connect.
  Policy: `two_factor` everywhere, including the OIDC clients. With a mail relay in site.json (`smtp`), enrolment
  codes and password resets go out by mail; without one reset is off and codes land in a file (below).
- Two dashboards: https://homelab.lsck0.dev for `admins` (widgets and their tokens), https://start.lsck0.dev for
  everyone else (links only).
- Authelia and the Proxmox realm read lldap as the read-only users `authelia-bind` and `proxmox-bind`
  (group `lldap_strict_readonly`); only the bootstrap and `lab-user` on vm-101 act as the lldap admin.
- Authelia's port 9091 answers only vm-100 and the granted probers (src/modules/flows.nix); the portal's
  password endpoints are rate limited per client on vm-100.

## Granting and revoking a service

Authorisation is lldap group membership. A route (an instance's `services.<name>`, an app's
`routes.<name>`) carries no group field: authelia derives `app-<route name>` (e.g. `app-homepage`
for homelab.lsck0.dev) for every route with sso in its `on` and turns it into an allow rule
for `admins` and that group plus a deny rule for the same host. OIDC clients check `app-<client id>` the same way. So:

- **to take a service away from someone**, `ssh 10.100.0.101 lab-user ungroup <name> app-<route>`. It takes
  effect within `refresh_interval` (5 minutes).
- groups: `admins` reach every page and are also put in lldap's built-in
  `lldap_admin`; everyone else gets one `app-<route>` group per page (e.g.
  `app-grafana`). There are no bundle groups. lldap seeds an `app-<route>`
  group for every sso route and every oidc client.
- a host no route names falls through to the last rule, which
  requires `admins`.

## Users

A password is asked for, never on a command line:
- `ssh 10.100.0.101 lab-user list`; `ssh 10.100.0.101 lab-user add <name> [group...]`;
  `ssh 10.100.0.101 lab-user passwd <name>`
- `ssh 10.100.0.101 lab-user groups <name> <group...>` grants pages,
  `ssh 10.100.0.101 lab-user ungroup <name> <group...>` takes them away
- `ssh 10.100.0.101 lab-user offboard <name>`: deletes the user and its second factors; it prints the apps that keep
  an account of their own (OIDC clients), which go by hand.
Send new passwords to the owner privately, never into a group chat.

## lldap via its GraphQL API (run on vm-101)

```
ssh 10.100.0.101 'TOKEN=$(curl -s -X POST localhost:17170/auth/simple/login -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$(cat /run/secrets/lldap-admin-password)\"}" | jq -r .token); \
  curl -s localhost:17170/api/graphql -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"query\":\"{ users { id email displayName groups { displayName } } }\"}"'
```
For what the user tool does not cover; groups by id: `{ groups { id displayName } }`.

## Authelia

- Logs: `ssh 10.100.0.101 journalctl -u authelia-main -n 100` (failed logins, bans).
- Reset a user's TOTP/WebAuthn: `ssh 10.100.0.101 authelia storage user totp delete <user> --config /etc/authelia/...`
  (find the config path with `systemctl cat authelia-main`).
- Regulation bans (too many failures) clear after the ban time or with `authelia storage` commands.
- Without a mail relay, one-time codes for device registration go to the filesystem notifier:
  `ssh 10.100.0.101 'cat /var/lib/authelia-main/notification.txt'`.
