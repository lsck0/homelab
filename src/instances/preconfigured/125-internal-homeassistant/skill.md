---
name: homeassistant
description: Home Assistant, its energy meters and tariffs.
version: 1.0.0
author: homelab
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [Homelab, HomeAssistant, IoT]
    related_skills: [homelab-ops]
---

# Home automation

## Home Assistant (vm-125, http://10.100.0.125)

Token `lab-token hass-key`, header `Authorization: Bearer <token>`.
- States: `GET /api/states`, one entity `GET /api/states/<entity_id>`.
- Call a service: `POST /api/services/<domain>/<service> {"entity_id":"light.kitchen"}`.
- Automations live in `/var/lib/homeassistant/automations.yaml` (local disk, mirrored to the NAS nightly); reload `POST /api/services/automation/reload`.
If it is disabled, say so; enabling it is `vm.power = "on"` in `src/instances/125-internal-homeassistant/instance.nix`.

## Energy meters and tariffs (the Energie dashboard)

The house energy dashboard (Energie sidebar in Home Assistant), the Grafana board "Energie" and the TRMNL
energy panel are driven by `input_number` helpers the owner sets by hand, defined in
`src/modules/energy/lib/inputs.nix`. Read one with `GET /api/states/input_number.<name>`; set one with:

`POST /api/services/input_number/set_value {"entity_id":"input_number.<name>","value":<number>}`

`set_value` needs the `input_number` domain and the numeric `value` field. When
the owner says "gas is at 1234.5" or "set the electricity price to 0.36", that is
this call. Meter readings are the absolute counter shown on the physical meter, in m³.

Meters (m³, absolute reading):
- `input_number.gas_meter`: Gaszähler.
- `input_number.water_meter`: Wasserzähler.

A typed reading is guarded (`src/instances/125-internal-homeassistant/lib/meter_reading.jinja`) before it counts. It becomes
`sensor.gas_meter_reading` / `sensor.water_meter_reading` (Prometheus: `hass_gas_meter_cubic_meters`,
`hass_water_meter_cubic_meters`; read time `sensor.<meter>_meter_read_at`, `hass_<meter>_meter_read_timestamp_seconds`)
only if it is plausible:
- a rise of at most 40 m³ gas or 3 m³ water per day since the last reading is taken;
- a value below the last reading but not below the one before it replaces the last reading (a typo fixed);
- anything else is rejected: a persistent notification says why and the helper is set back to the accepted value.
After a set_value, read `sensor.<meter>_meter_reading` to confirm it was taken, and tell the owner if not.

Fixing a reading: a too-high typo is fixed by entering the right value. A rejected value means a decimal slip,
"327.8" for "3278": enter it again correctly. A new meter (replaced by the utility): press
`input_button.<meter>_meter_replaced` (`POST /api/services/input_button/press`), then enter the new meter's reading.
Consumption is always the last accepted reading minus the lowest one in the window, so a corrected typo never
counts as use.

Tariffs (set when a contract changes):
- `input_number.price_electricity`: Strompreis, EUR/kWh.
- `input_number.price_feed_in`: Einspeisevergütung, EUR/kWh.
- `input_number.price_gas`: Gaspreis, EUR/kWh.
- `input_number.price_water`: Wasserpreis, EUR/m³.
- `input_number.gas_kwh_per_m3`: gas m³ to kWh conversion factor (on the gas bill).
- `input_number.fee_electricity` / `input_number.fee_gas` / `input_number.fee_water`: monthly base fee (Grundpreis), EUR/Monat.

A tariff at 0 counts as unset: every cost that needs it shows "-" until it is set.
