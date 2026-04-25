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
  networking.hostName = "vm-115";

  fileSystems = nasMount "/var/lib/homeassistant" "homeassistant"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:stable";
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

  # Generate long-lived access token for Homepage widget
  systemd.services.hass-homepage-token = {
    description = "Generate Home Assistant token for Homepage";
    after = [ "podman-homeassistant.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.gnugrep
      (pkgs.python3.withPackages (ps: [ ps.websockets ]))
    ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/hass-key.token"
      [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ] && exit 0
      # Wait for HA to be ready
      for i in $(seq 1 120); do
        curl -sf http://127.0.0.1:80/api/ >/dev/null 2>&1 && break
        # Also accept 401 (means HA is up but needs auth)
        CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://127.0.0.1:80/api/ 2>/dev/null || true)
        [ "$CODE" = "401" ] && break
        sleep 2
      done

      # Complete onboarding if needed
      ONBOARD=$(curl -sf http://127.0.0.1:80/api/onboarding 2>/dev/null || true)
      if echo "$ONBOARD" | grep -q '"done":false'; then
        AUTH_CODE=$(curl -sf -X POST "http://127.0.0.1:80/api/onboarding/users" \
          -H "Content-Type: application/json" \
          -d '{"client_id":"http://127.0.0.1:80/","name":"Admin","username":"admin","password":"admin","language":"en"}' 2>/dev/null \
          | grep -oP '"auth_code"\s*:\s*"\K[^"]+' || true)
        [ -z "$AUTH_CODE" ] && exit 1

        ACCESS_TOKEN=$(curl -sf -X POST "http://127.0.0.1:80/auth/token" \
          -d "grant_type=authorization_code&code=$AUTH_CODE&client_id=http://127.0.0.1:80/" 2>/dev/null \
          | grep -oP '"access_token"\s*:\s*"\K[^"]+' || true)

        # Complete remaining onboarding steps
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
        # Already onboarded — authenticate
        ACCESS_TOKEN=$(curl -sf -X POST "http://127.0.0.1:80/auth/token" \
          -d "grant_type=password&username=admin&password=admin&client_id=http://127.0.0.1:80/" 2>/dev/null \
          | grep -oP '"access_token"\s*:\s*"\K[^"]+' || true)
      fi
      [ -z "$ACCESS_TOKEN" ] && exit 1

      # Create long-lived access token via WebSocket API
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
