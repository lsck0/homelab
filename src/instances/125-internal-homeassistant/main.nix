{ config, pkgs, lib, inventory, site, catalog, retry, setupUnit, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  route = catalog.internal.homeassistant;
  containerPort = 8123;
  local = "http://127.0.0.1:${toString route.port}";
  stateDir = "/var/lib/homeassistant";
  uid = "1000";
  tokensDir = config.homelab.tokens.dir;
  # the onboarding admin's login, used once on a fresh install: auth_providers below allows oidc only
  adminPassword = config.sops.secrets.hass-pass.path;
  # the onboarding api's client: home assistant's own frontend at the address the setup calls
  onboardingClientId = "${local}/";
  longLivedTokenLifespanDays = 3650;

  # login through authelia oidc; the release zip, not the git tag: only it carries the built style.css
  oidcAuth = pkgs.fetchzip {
    url = "https://github.com/christiaangoossens/hass-oidc-auth/releases/download/v1.2.1/hass-oidc-auth.zip";
    stripRoot = false;
    # bump the css cache-buster: cloudflare cached the pre-fix 404 for 31 days under ?v=5
    postFetch = "sed -i 's|style.css?v=5|style.css?v=lab1|' $out/views/templates/base.html";
    hash = "sha256-BJD5E5nG9CosPdbsSqP5t2bDKXYWD0HLcVWNgCVcFH4=";
  };

  # the hand-typed energy inputs: helpers, guarded meter sensors, prometheus names and the Energie dashboard
  energy = import ./lib/home-assistant.nix { inherit lib; };
  energieDashboard = pkgs.writeText "energie.yaml" energy.dashboard;

  hassConfig = pkgs.writeText "configuration.yaml" ''
    homeassistant:
      # energy dashboard needs these for cost and units, else it prompts on first open
      country: DE
      currency: EUR
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
      discovery_url: https://${net.fqdn catalog.internal.authelia.host}/.well-known/openid-configuration
      display_name: Authelia
      features:
        automatic_user_linking: true
        default_redirect: true
        force_https: true
      roles:
        admin: admins
        user: app-homeassistant

    # meter readings and tariffs typed in from the app, and what was accepted of them
    input_number: ${energy.inputNumbers}
    input_button: ${energy.inputButtons}
    template: ${energy.templates}

    # a dashboard just for the manual energy inputs (solar/pv live on grafana + trmnl)
    lovelace:
      dashboards:
        energie-dashboard:
          mode: yaml
          title: Energie
          icon: mdi:transmission-tower
          show_in_sidebar: true
          filename: energie.yaml

    # scraped by prometheus on vm-105
    prometheus: ${energy.prometheus}
  '';

  # 2026.9 ignores yaml http:, hass-http writes .storage
  httpStable = builtins.toJSON {
    server_port = containerPort;
    server_host = [ "0.0.0.0" ];
    use_x_forwarded_for = true;
    trusted_proxies = [ (net.hostSource net.zones.internal.ingress) ];
  };

  # the long-lived token over the websocket api; the access token comes in the environment, never on argv
  longLivedToken = pkgs.writeText "hass-long-lived-token.py" ''
    import asyncio
    import json
    import os
    import sys

    import websockets


    async def main():
        async with websockets.connect("ws://127.0.0.1:${toString route.port}/api/websocket") as ws:
            await ws.recv()  # auth_required
            await ws.send(json.dumps({"type": "auth", "access_token": os.environ["ACCESS_TOKEN"]}))
            await ws.recv()  # auth_ok
            await ws.send(json.dumps({"id": 1, "type": "auth/long_lived_access_token", "client_name": "Homepage",
                                      "lifespan": ${toString longLivedTokenLifespanDays}}))
            response = json.loads(await ws.recv())
            if not response.get("success"):
                sys.exit(f"home assistant minted no long-lived token: {response}")
            print(response["result"], end="")


    asyncio.run(main())
  '';
in {
  # the recorder's sqlite wal dies of SIGBUS on nfs; local, the nas keeps a nightly copy
  homelab.localState.homeassistant = {
    path = stateDir;
    unit = "podman-homeassistant";
    sqlite = [ "home-assistant_v2.db" ];
    exclude = [ ".cache" "home-assistant.log*" ];
  };

  virtualisation.oci-containers.containers.homeassistant = {
    image = "ghcr.io/home-assistant/home-assistant:2026.9.2";
    ports = [ "${toString route.port}:${toString containerPort}" ];
    volumes = [
      "${stateDir}:/config"
      "${hassConfig}:/config/configuration.yaml:ro"
      "${energieDashboard}:/config/energie.yaml:ro"
      "${energy.meterGuard}:/config/custom_templates/${energy.meterGuardName}:ro"
      "${oidcAuth}:/config/custom_components/auth_oidc:ro"
    ];
  };

  sops.secrets.homeassistant-oidc-secret = {};
  sops.secrets.hass-pass = {};

  systemd.services.hass-http = {
    before = [ "podman-homeassistant.service" ];
    requiredBy = [ "podman-homeassistant.service" ];
    after = [ "homeassistant-seed.service" ];
    path = [ pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      f=${stateDir}/.storage/http
      mkdir -p "$(dirname $f)"
      [ -s $f ] || echo '{"version":2,"minor_version":2,"key":"http","data":{"stable":{}}}' > $f
      jq --argjson h '${httpStable}' \
        '.data.stable += $h | .data.stable.error = null | .data.pending = null | .data.yaml_migration_done = true' \
        $f > $f.new && mv $f.new $f
      (umask 077; printf 'oidc_secret: "%s"\n' "$(cat ${config.sops.secrets.homeassistant-oidc-secret.path})" > ${stateDir}/secrets.yaml)
      chown ${uid}:${uid} $f ${stateDir}/secrets.yaml
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 ${uid} ${uid} -"
    "d ${stateDir}/themes 0750 ${uid} ${uid} -"
    # the mount point of the meter guard macro
    "d ${stateDir}/custom_templates 0750 ${uid} ${uid} -"
    "f ${stateDir}/automations.yaml 0640 ${uid} ${uid} -"
    "f ${stateDir}/scripts.yaml 0640 ${uid} ${uid} -"
    "f ${stateDir}/scenes.yaml 0640 ${uid} ${uid} -"
  ];

  # the homepage widget's token; onboarding is the only unattended way to one, so a fresh install gets it
  systemd.services.hass-homepage-token = setupUnit {
    description = "Generate Home Assistant token for Homepage";
    after = [ "podman-homeassistant.service" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq (pkgs.python3.withPackages (ps: [ ps.websockets ])) ];
    script = ''
      [ -s ${tokensDir}/hass-key.token ] && exit 0
      # any http answer means it is up, a 401 included
      ${retry} 120 2 curl -s -o /dev/null ${local}/api/
      onboarding=$(curl -sf ${local}/api/onboarding)
      if ! jq -e 'any(.[]; .done == false)' <<<"$onboarding" >/dev/null; then
        echo "Home Assistant is onboarded but hass-key.token is missing: create a long-lived token in the UI" >&2
        exit 1
      fi

      auth_code=$(jq -cn --rawfile p ${adminPassword} \
          '{client_id: "${onboardingClientId}", name: "Admin", username: "admin", password: $p, language: "en"}' \
        | curl -sf -X POST ${local}/api/onboarding/users -H "Content-Type: application/json" -d @- \
        | jq -er .auth_code)
      access_token=$(curl -sf -X POST ${local}/auth/token \
          -d "grant_type=authorization_code&code=$auth_code&client_id=${onboardingClientId}" \
        | jq -er .access_token)

      # the rest of the wizard; the token does not depend on it
      onboarding_step() { # <step> <json body>
        curl -sf -X POST "${local}/api/onboarding/$1" -H "Authorization: Bearer $access_token" \
          -H "Content-Type: application/json" -d "$2" >/dev/null || echo "onboarding step $1 failed" >&2
      }
      onboarding_step core_config '{}'
      onboarding_step analytics '{}'
      onboarding_step integration '{"client_id":"${onboardingClientId}"}'

      ACCESS_TOKEN=$access_token python3 ${longLivedToken} | token_write hass-key
    '';
  };
}
