{ pkgs, nasMount, ... }:
let
  hassConfig = pkgs.writeText "configuration.yaml" ''
    default_config:
    frontend:
      themes: !include_dir_merge_named themes
    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml
    http:
      server_host: 0.0.0.0
      use_x_forwarded_for: true
      trusted_proxies:
        - 10.100.0.0/24
        - 10.0.0.0/8
  '';
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
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/homeassistant 0750 1000 1000 -"
    "d /var/lib/homeassistant/themes 0750 1000 1000 -"
    "f /var/lib/homeassistant/automations.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scripts.yaml 0640 1000 1000 -"
    "f /var/lib/homeassistant/scenes.yaml 0640 1000 1000 -"
  ];

  # generate long-lived access token for Homepage widget
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
      # wait for HA to be ready
      for i in $(seq 1 120); do
        curl -sf http://127.0.0.1:80/api/ >/dev/null 2>&1 && break
        # also accept 401 (means HA is up but needs auth)
        CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:80/api/ 2>/dev/null || true)
        [ "$CODE" = "401" ] && break
        sleep 2
      done

      # onboarding is the only unattended way to a token: HA has no password
      # grant, so an onboarded instance without a token file needs a manual one.
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

        # complete remaining onboarding steps
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

      # create long-lived access token via WebSocket API
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

  networking.firewall.allowedTCPPorts = [ 80 ];
}
