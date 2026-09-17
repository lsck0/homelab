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

- Alert topic (the owner's phone subscribes): `lsck0-homelab-a7f3k9d2xq`.
- Send: `curl -s -H "Title: <title>" -H "Priority: default" -H "Tags: warning" -d "<text>" http://10.200.0.203/lsck0-homelab-a7f3k9d2xq`
  Priorities: min, low, default, high, urgent. Click URL: `-H "Click: https://..."`.
- Prefer replying on Telegram. Use ntfy for long-running jobs that finish later
  (e.g. a restore or download finished) or when Telegram is unavailable.
- Scheduled checks: create a Hermes cron job that runs the check and messages the owner.
