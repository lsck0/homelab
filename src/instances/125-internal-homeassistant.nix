{ config, pkgs, nasMount, ... }:
let
  # login through authelia oidc
  oidcAuth = pkgs.fetchFromGitHub {
    owner = "christiaangoossens";
    repo = "hass-oidc-auth";
    rev = "v1.2.1";
    hash = "sha256-vwQDrMM4phbrXT85Syyz6hWEIhLB3TKNNTM04OdvNWk=";
  };

  hassConfig = pkgs.writeText "configuration.yaml" ''
    homeassistant:
      # authelia oidc only: the route has no forwardauth, a password login would skip its 2fa
      auth_providers: []
    default_config:
    frontend:
      themes: !include_dir_merge_named themes
    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml
    auth_oidc:
      client_id: homeassistant
      client_secret: !secret oidc_secret
      discovery_url: https://auth.lsck0.dev/.well-known/openid-configuration
      display_name: Authelia
      features:
        automatic_user_linking: true
        default_redirect: true
        force_https: true
      roles:
        admin: admins
        user: app-homeassistant

    # meter readings typed in daily from the app
    input_number:
      gas_meter:
        name: Gaszähler
        icon: mdi:meter-gas
        unit_of_measurement: "m³"
        mode: box
        min: 0
        max: 999999
        step: 0.001
      water_meter:
        name: Wasserzähler
        icon: mdi:water
        unit_of_measurement: "m³"
        mode: box
        min: 0
        max: 999999
        step: 0.001
      # contract prices, kept here so a tariff change is one edit in the app
      price_electricity:
        name: Strompreis
        icon: mdi:cash
        unit_of_measurement: "EUR/kWh"
        mode: box
        min: 0
        max: 10
        step: 0.0001
      price_feed_in:
        name: Einspeisevergütung
        icon: mdi:cash-plus
        unit_of_measurement: "EUR/kWh"
        mode: box
        min: 0
        max: 10
        step: 0.0001
      price_gas:
        name: Gaspreis
        icon: mdi:cash
        unit_of_measurement: "EUR/kWh"
        mode: box
        min: 0
        max: 10
        step: 0.0001
      # brennwert times zustandszahl, from the gas bill
      gas_kwh_per_m3:
        name: Gas Umrechnung
        icon: mdi:swap-horizontal
        unit_of_measurement: "kWh/m³"
        mode: box
        min: 0
        max: 20
        step: 0.0001
      price_water:
        name: Wasserpreis
        icon: mdi:cash
        unit_of_measurement: "EUR/m³"
        mode: box
        min: 0
        max: 100
        step: 0.01
      fee_electricity:
        name: Grundpreis Strom
        icon: mdi:calendar-month
        unit_of_measurement: "EUR/Monat"
        mode: box
        min: 0
        max: 1000
        step: 0.01
      fee_gas:
        name: Grundpreis Gas
        icon: mdi:calendar-month
        unit_of_measurement: "EUR/Monat"
        mode: box
        min: 0
        max: 1000
        step: 0.01
      fee_water:
        name: Grundpreis Wasser
        icon: mdi:calendar-month
        unit_of_measurement: "EUR/Monat"
        mode: box
        min: 0
        max: 1000
        step: 0.01

    # energy dashboard only takes sensors with a state class
    template:
      - sensor:
          - name: Gaszählerstand
            unique_id: gas_meter_reading
            unit_of_measurement: "m³"
            device_class: gas
            state_class: total_increasing
            state: "{{ states('input_number.gas_meter') | float(0) }}"
            # 0 is the unset helper, not a reading
            availability: "{{ states('input_number.gas_meter') | float(0) > 0 }}"
          - name: Wasserzählerstand
            unique_id: water_meter_reading
            unit_of_measurement: "m³"
            device_class: water
            state_class: total_increasing
            state: "{{ states('input_number.water_meter') | float(0) }}"
            availability: "{{ states('input_number.water_meter') | float(0) > 0 }}"

    # scraped by prometheus on vm-105
    prometheus:
      namespace: hass
      filter:
        include_entities:
          - sensor.gas_meter_reading
          - sensor.water_meter_reading
        include_entity_globs:
          - input_number.*
      # default name escapes the unit to sensor_gas_mu0xb3
      component_config:
        sensor.gas_meter_reading:
          override_metric: gas_meter_cubic_meters
        sensor.water_meter_reading:
          override_metric: water_meter_cubic_meters
  '';

  # 2026.9 ignores yaml http:, hass-http writes .storage
  httpStable = builtins.toJSON {
    server_port = 8123;
    server_host = [ "0.0.0.0" ];
    use_x_forwarded_for = true;
    trusted_proxies = [ "10.100.0.100/32" ];
  };
in {
  networking.hostName = "vm-125";

  fileSystems = nasMount "/var/lib/homeassistant" "homeassistant"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:2026.9.2";
    ports = [ "80:8123" ];
    volumes = [
      "/var/lib/homeassistant:/config"
      "${hassConfig}:/config/configuration.yaml:ro"
      "${oidcAuth}/custom_components/auth_oidc:/config/custom_components/auth_oidc:ro"
    ];
  };

  sops.secrets.homeassistant-oidc-secret = {};

  systemd.services.hass-http = {
    before = [ "podman-homeassistant.service" ];
    requiredBy = [ "podman-homeassistant.service" ];
    unitConfig.RequiresMountsFor = [ "/var/lib/homeassistant" ];
    path = [ pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      f=/var/lib/homeassistant/.storage/http
      mkdir -p "$(dirname $f)"
      [ -s $f ] || echo '{"version":2,"minor_version":2,"key":"http","data":{"stable":{}}}' > $f
      jq --argjson h '${httpStable}' \
        '.data.stable += $h | .data.stable.error = null | .data.pending = null | .data.yaml_migration_done = true' \
        $f > $f.new && mv $f.new $f
      printf 'oidc_secret: "%s"\n' "$(cat ${config.sops.secrets.homeassistant-oidc-secret.path})" > /var/lib/homeassistant/secrets.yaml
      chmod 600 /var/lib/homeassistant/secrets.yaml
      chown 1000:1000 $f /var/lib/homeassistant/secrets.yaml
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant 0750 1000 1000 -"
    "d /var/lib/homeassistant/themes 0750 1000 1000 -"
    "f /var/lib/homeassistant/automations.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scripts.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scenes.yaml 0640 1000 1000 -"
  ];

  # long-lived token for the homepage widget
  systemd.services.hass-homepage-token = {
    description = "Generate Home Assistant token for Homepage";
    after = [ "podman-homeassistant.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.jq pkgs.openssl
      (pkgs.python3.withPackages (ps: [ ps.websockets ]))
    ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/hass-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # wait for ha
      for i in $(seq 1 120); do
        curl -sf http://127.0.0.1:80/api/ >/dev/null 2>&1 && break
        # 401 still means up
        CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:80/api/ 2>/dev/null || true)
        [ "$CODE" = "401" ] && break
        sleep 2
      done

      # onboarding is the only unattended token path
      ONBOARD=$(curl -sf http://127.0.0.1:80/api/onboarding 2>/dev/null || true)
      if echo "$ONBOARD" | grep -q '"done":false'; then
        [ -s /var/lib/homepage-tokens/hass-pass.token ] || openssl rand -hex 16 | tr -d '\n' > /var/lib/homepage-tokens/hass-pass.token
        AUTH_CODE=$(curl -sf -X POST "http://127.0.0.1:80/api/onboarding/users" \
          -H "Content-Type: application/json" \
          -d "$(jq -cn --rawfile p /var/lib/homepage-tokens/hass-pass.token '{client_id:"http://127.0.0.1:80/", name:"Admin", username:"admin", password:$p, language:"en"}')" 2>/dev/null \
          | grep -oP '"auth_code"\s*:\s*"\K[^"]+' || true)
        [ -z "$AUTH_CODE" ] && exit 1

        ACCESS_TOKEN=$(curl -sf -X POST "http://127.0.0.1:80/auth/token" \
          -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=http://127.0.0.1:80/" 2>/dev/null \
          | grep -oP '"access_token"\s*:\s*"\K[^"]+' || true)

        # finish remaining onboarding steps
        for step in core_config analytics; do
          curl -sf -X POST "http://127.0.0.1:80/api/onboarding/$step" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" -d '{}' 2>/dev/null || true
        done
        curl -sf -X POST "http://127.0.0.1:80/api/onboarding/integration" \
          -H "Authorization: Bearer $ACCESS_TOKEN" \
          -H "Content-Type: application/json" \
          -d '{"client_id":"http://127.0.0.1:80/"}' 2>/dev/null || true
      else
        echo "Home Assistant is onboarded but $TOKEN_FILE is missing: create a long-lived token in the UI" >&2
        exit 1
      fi
      [ -z "$ACCESS_TOKEN" ] && exit 1

      # long-lived token via websocket api
      LLAT=$(python3 -c "
      import asyncio, json, websockets
      async def main():
          async with websockets.connect('ws://127.0.0.1:80/api/websocket') as ws:
              await ws.recv()  # auth_required
              await ws.send(json.dumps({'type': 'auth', 'access_token': '$ACCESS_TOKEN'}))
              await ws.recv()  # auth_ok
              await ws.send(json.dumps({'id': 1, 'type': 'auth/long_lived_access_token', 'client_name': 'Homepage', 'lifespan': 3650}))
              resp = json.loads(await ws.recv())
              if resp.get('success'):
                  print(resp['result'])
      asyncio.run(main())
      " 2>/dev/null || true)

      if [ -n "$LLAT" ]; then
        echo -n "$LLAT" > "$TOKEN_FILE"
        echo "Home Assistant Homepage token created"
      fi
    '';
  };

  # mqtt bus for home assistant, zigbee2mqtt, esphome; lan only, never forwarded
  services.mosquitto = {
    enable = true;
    listeners = [{
      address = "0.0.0.0";
      port = 1883;
      settings.allow_anonymous = true;
      omitPasswordAuth = true;
      acl = [ "topic readwrite #" ];
    }];
  };

  networking.firewall.allowedTCPPorts = [ 80 1883 ];
  homelab.ingressOnly.ports = [ 80 ];
}
