---
name: notifications
description: Send push notifications to the owner via ntfy.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, ntfy, Notifications]
    related_skills: [homelab-ops]
---

# Notifications (ntfy on vm-203, https://ntfy.lsck0.dev)

- ntfy requires a login now: `auth-default-access` is `deny-all`, so an
  anonymous publish or subscribe is rejected and topic names are no longer
  secrets. Accounts are seeded by `ntfy-users.service` on vm-203.
- Your account is `hermes`, password in sops as `ntfy-hermes-password`, and it
  may read and write exactly one topic: `homelab-hermes`.
- Send: `curl -s -u "hermes:$(cat /run/secrets/ntfy-hermes-password)" -H "Title: <title>" -H "Priority: default" -H "Tags: warning" -d "<text>" http://10.200.0.203/homelab-hermes`
  Priorities: min, low, default, high, urgent. Click URL: `-H "Click: https://..."`.
- `homelab-alerts` is Grafana's topic and the `grafana` account is write-only on
  it. Do not publish there: the owner reads it as the alert channel.
- Adding a topic or an account means editing the `users` set in
  `src/instances/203-external-ntfy.nix` and deploying; `ntfy access <user>
  <topic> <perm>` by hand is undone on the next activation.
- Prefer replying on Telegram. Use ntfy for long-running jobs that finish later
  (e.g. a restore or download finished) or when Telegram is unavailable.
- Scheduled checks: create a Hermes cron job that runs the check and messages the owner.
