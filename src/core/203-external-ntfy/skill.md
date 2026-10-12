---
name: ntfy
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

- Send the owner a push: `lab-notify [-t <title>] [-p min|low|default|high|urgent] [-g <tags>] [-c <click url>] <text>`.
  It publishes to topic `homelab-hermes` as user `hermes`; the password stays inside the tool.
- ntfy requires a login (`auth-default-access` is `deny-all`). Every account and every topic grant is declared
  in `src/instances/203-external-ntfy/main.nix` (`users`): ntfy provisions exactly those at start, and an account made
  by hand is deleted on the next start. A new topic or account is an edit there plus a deploy by the owner.
- `homelab-alerts` is Grafana's topic and the owner's alert channel; `homelab-heartbeat` is Grafana's watchdog.
  Never publish to either: `hermes` may not, and a message there would read as an alert.
- Prefer replying on Telegram. Use `lab-notify` for long-running jobs that finish later (a restore or a download
  finished) or when Telegram is unavailable.
- Scheduled checks: create a Hermes cron job that runs the check and messages the owner.
