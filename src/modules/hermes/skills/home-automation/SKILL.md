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

## MQTT (vm-125 (with Home Assistant), 10.100.0.125:1883, anonymous on the LAN)

- Publish: `mosquitto_pub -h 10.100.0.125 -t <topic> -m '<payload>'` (install on demand: `nix shell nixpkgs#mosquitto`, or run it on vm-125 via ssh).
- Watch: `ssh 10.100.0.125 "mosquitto_sub -t '#' -v -W 10"`.

## Home Assistant (vm-125, http://10.100.0.125)

Token `lab-token hass-key`, header `Authorization: Bearer <token>`.
- States: `GET /api/states`, one entity `GET /api/states/<entity_id>`.
- Call a service: `POST /api/services/<domain>/<service> {"entity_id":"light.kitchen"}`.
- Automations live in `/var/lib/homeassistant/automations.yaml` (NAS); reload `POST /api/services/automation/reload`.
If it is disabled, say so; enabling it is `enabled = true` for 124 in `src/instances.tf`.

## Energy meters and tariffs (the Energie dashboard)

The house energy dashboard (Energie sidebar in Home Assistant) and the TRMNL
energy panel are driven by `input_number` helpers the owner sets by hand. Read
one with `GET /api/states/input_number.<name>`; set one with:

`POST /api/services/input_number/set_value {"entity_id":"input_number.<name>","value":<number>}`

`set_value` needs the `input_number` domain and the numeric `value` field. When
the owner says "gas is at 1234.5" or "set the electricity price to 0.36", that is
this call. Meter readings are the absolute counter shown on the physical meter,
in the unit below; the dashboard derives usage from the change over time.

Meters (m³, absolute reading):
- `input_number.gas_meter` — Gaszähler.
- `input_number.water_meter` — Wasserzähler.

Tariffs (set when a contract changes):
- `input_number.price_electricity` — Strompreis, EUR/kWh.
- `input_number.price_feed_in` — Einspeisevergütung, EUR/kWh.
- `input_number.price_gas` — Gaspreis, EUR/kWh.
- `input_number.price_water` — Wasserpreis, EUR/m³.
- `input_number.gas_kwh_per_m3` — gas m³→kWh conversion factor (on the gas bill).
- `input_number.fee_electricity` / `input_number.fee_gas` / `input_number.fee_water` — monthly base fee (Grundpreis), EUR/Monat.

The gas/water readings flow to `sensor.gas_meter_reading` / `sensor.water_meter_reading`,
which Prometheus scrapes and `energy-sync.py` renders on the TRMNL panel, so a new
reading shows up there after the next scrape.
