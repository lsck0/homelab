---
name: home-automation
description: Home Assistant and MQTT (Mosquitto).
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, HomeAssistant, MQTT, IoT]
    related_skills: [homelab-ops]
---

# Home automation

## MQTT (vm-126, 10.100.0.126:1883, anonymous on the LAN)

- Publish: `mosquitto_pub -h 10.100.0.126 -t <topic> -m '<payload>'` (install on demand: `nix shell nixpkgs#mosquitto`, or run it on vm-126 via ssh).
- Watch: `ssh 10.100.0.126 "mosquitto_sub -t '#' -v -W 10"`.

## Home Assistant (vm-124, http://10.100.0.124, currently enabled = false)

If enabled: token `lab-token hass-key`, header `Authorization: Bearer <token>`.
- States: `GET /api/states`, one entity `GET /api/states/<entity_id>`.
- Call a service: `POST /api/services/<domain>/<service> {"entity_id":"light.kitchen"}`.
- Automations live in `/var/lib/homeassistant/automations.yaml` (NAS); reload `POST /api/services/automation/reload`.
If it is disabled, say so; enabling it is `enabled = true` for 124 in `src/instances.tf`.
