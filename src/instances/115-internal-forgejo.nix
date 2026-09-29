{ config, pkgs, nasMount, retry, ... }: {
  imports = [ ../services/forgejo-runner.nix ];

  networking.hostName = "vm-115";

  # the runner needs docker for its job containers, so forgejo runs on docker too
  virtualisation.oci-containers.backend = "docker";

  fileSystems = nasMount "/var/lib/forgejo" "forgejo"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets.forgejo-oidc-secret = {};
  sops.secrets.forgejo-admin-pass = {};

  virtualisation.oci-containers.containers.forgejo = {
    image = "codeberg.org/forgejo/forgejo:7.0.16";
    ports = [ "80:3000" "2222:22" ];
    volumes = [ "/var/lib/forgejo:/data" ];
    extraOptions = [ "--add-host=auth.lsck0.dev:10.100.0.100" ];
    environment = {
      FORGEJO__server__HTTP_PORT = "3000";
      FORGEJO__server__ROOT_URL = "https://git.lsck0.dev/";
      FORGEJO__security__INSTALL_LOCK = "true";
      FORGEJO__actions__ENABLED = "true";
      # sso-only, nothing visible without login
      FORGEJO__service__DISABLE_REGISTRATION = "true";
      FORGEJO__service__ALLOW_ONLY_EXTERNAL_REGISTRATION = "true";
      FORGEJO__service__REQUIRE_SIGNIN_VIEW = "true";
      FORGEJO__service__ENABLE_BASIC_AUTHENTICATION = "false";
      FORGEJO__openid__ENABLE_OPENID_SIGNIN = "false";
      FORGEJO__oauth2_client__ENABLE_AUTO_REGISTRATION = "true";
      FORGEJO__oauth2_client__ACCOUNT_LINKING = "auto";
      FORGEJO__oauth2_client__USERNAME = "nickname";
    };
  };

  # create the first admin once, idempotent
  systemd.services.forgejo-init = {
    description = "Initialise Forgejo admin user";
    after = [ "docker-forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.docker ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      # skip if users already exist
      COUNT=$(docker exec -u git forgejo forgejo admin user list 2>/dev/null | grep -c '^[0-9]' || echo 0)
      [ "$COUNT" -gt 0 ] && { echo "Users exist ($COUNT), skipping init"; exit 0; }

      PASS=$(cat ${config.sops.secrets.forgejo-admin-pass.path})
      docker exec -u git forgejo forgejo admin user create \
        --admin \
        --username luca \
        --password "$PASS" \
        --email luca.sandrock@proton.me \
        --must-change-password=false
      echo "Admin user created"
    '';
  };

  # configure the oauth2 source once forgejo is up
  systemd.services.forgejo-oauth2-setup = {
    description = "Configure Forgejo OAuth2 with Authelia";
    after = [ "docker-forgejo.service" "forgejo-init.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.docker pkgs.gawk pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      OIDC_SECRET=$(cat ${config.sops.secrets.forgejo-oidc-secret.path})
      DISCOVER_URL="https://auth.lsck0.dev/.well-known/openid-configuration"

      # name is the button label; authelia registers both callbacks
      sources=$(docker exec -u git forgejo forgejo admin auth list 2>/dev/null || true)
      AUTH_ID=$(echo "$sources" | grep -w authelia  | awk '{print $1}')
      OLD_ID=$(echo "$sources"  | grep -w authentik | awk '{print $1}')

      if [ -z "$AUTH_ID" ] && [ -n "$OLD_ID" ]; then
        echo "renaming the authentik OAuth2 source to authelia (id=$OLD_ID)"
        AUTH_ID="$OLD_ID"
        docker exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" --name authelia || true
      fi

      # explicit scopes, "openid" alone breaks signup; errors shown
      if [ -n "$AUTH_ID" ]; then
        echo "OAuth2 source exists (id=$AUTH_ID), updating..."
        docker exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" \
          --name authelia \
          --secret "$OIDC_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          --scopes openid --scopes profile --scopes email \
          || echo "WARNING: could not update the authelia OAuth2 source"
        exit 0
      fi

      # create via Forgejo CLI inside container
      docker exec -u git forgejo forgejo admin auth add-oauth \
        --name authelia \
        --provider openidConnect \
        --key forgejo \
        --secret "$OIDC_SECRET" \
        --auto-discover-url "$DISCOVER_URL" \
        --scopes openid --scopes profile --scopes email \
        --skip-local-2fa \
        2>/dev/null || echo "Auth source may already exist"
    '';
  };

  # api token for the homepage widget
  systemd.services.forgejo-homepage-token = {
    description = "Generate Forgejo API token for Homepage";
    after = [ "docker-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.docker pkgs.gawk pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/forgejo-key.token"

      # clear only on 401, not on network errors
      if [ -f "$TOKEN_FILE" ] && [ -s "$TOKEN_FILE" ]; then
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: token $(cat "$TOKEN_FILE")" \
          http://127.0.0.1:80/api/v1/user 2>/dev/null)
        case "$HTTP" in
          200) echo "Homepage token valid"; exit 0 ;;
          401) echo "Homepage token stale, regenerating..."; rm -f "$TOKEN_FILE" ;;
          *)   echo "Homepage token check inconclusive (HTTP $HTTP), keeping token"; exit 0 ;;
        esac
      fi

      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      # local bot user for api access
      docker exec -u git forgejo forgejo admin user create \
        --username homepage-bot \
        --password "homepage-bot-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --email homepage@lsck0.dev \
        --must-change-password=false 2>/dev/null || true

      # token is the last field; timestamped name allows retry
      TOKEN=$(docker exec -u git forgejo forgejo admin user generate-access-token \
        --username homepage-bot \
        --token-name "homepage-$(date +%s)" \
        --scopes read:activitypub,read:issue,read:misc,read:notification,read:organization,read:package,read:repository,read:user \
        | tr -d '\r' | awk 'END {print $NF}' || true)

      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Forgejo Homepage token created"
      else
        echo "Token may already exist or creation failed"
      fi
    '';
  };

  # hermes needs an admin token, homepage-bot is read-only
  systemd.services.forgejo-hermes-token = {
    description = "Generate a Forgejo admin token for Hermes";
    after = [ "docker-forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker pkgs.curl pkgs.coreutils pkgs.gawk ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/forgejo-hermes.token"

      if [ -s "$TOKEN_FILE" ]; then
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "Authorization: token $(cat $TOKEN_FILE)" \
          http://127.0.0.1:80/api/v1/user || echo 000)
        case "$HTTP" in
          200) echo "Hermes token valid"; exit 0 ;;
          401) echo "Hermes token stale, regenerating..."; rm -f "$TOKEN_FILE" ;;
          *)   echo "Hermes token check inconclusive (HTTP $HTTP), keeping it"; exit 0 ;;
        esac
      fi

      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      docker exec -u git forgejo forgejo admin user create \
        --username hermes-bot \
        --password "hermes-bot-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --email hermes@lsck0.dev \
        --admin \
        --must-change-password=false 2>/dev/null || true

      # "all": hermes operates the forge
      TOKEN=$(docker exec -u git forgejo forgejo admin user generate-access-token \
        --username hermes-bot \
        --token-name "hermes-$(date +%s)" \
        --scopes all \
        | tr -d '\r' | awk 'END {print $NF}' || true)

      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Forgejo Hermes admin token created"
      else
        echo "Hermes token creation failed"
      fi
    '';
  };

  # runner registration token, shared via nas
  systemd.services.forgejo-runner-token = {
    description = "Generate Forgejo runner registration token";
    after = [ "docker-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 docker exec -u git forgejo forgejo admin user list

      # always regenerate, tokens are one-use
      TOKEN=$(docker exec -u git forgejo forgejo actions generate-runner-token 2>/dev/null || true)
      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > /var/lib/homepage-tokens/forgejo-runner.token
        echo "Runner token generated"
      fi
    '';
  };

  # GitHub mirrors
  # github is the source, forgejo pull-mirrors each repo
  sops.secrets.github-mirror-token = {};

  systemd.services.forgejo-mirror = {
    description = "Mirror every GitHub repository into Forgejo";
    after = [ "docker-forgejo.service" "forgejo-init.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.docker pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "forgejo-mirror";
    };
    environment = {
      FORGEJO_OWNER = "luca";
      GITHUB_OWNER = "lsck0";
      # forgejo's own re-fetch interval
      MIRROR_INTERVAL = "8h";
      FORGEJO_TOKEN_FILE = "/var/lib/forgejo-mirror/token";
      GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      # own write token, timestamped for retries, checked before storing
      if [ ! -s /var/lib/forgejo-mirror/token ]; then
        out=$(docker exec -u git forgejo forgejo admin user generate-access-token \
          --username luca --token-name "mirror-$(date +%s)" \
          --scopes write:repository,read:user)
        tok=$(printf '%s' "$out" | tr -d '\r' | awk 'END {print $NF}')
        case "$tok" in
          ????????????????????????????????????????) ;;
          *) echo "ERROR: unexpected output from generate-access-token: $out"; exit 1 ;;
        esac
        printf '%s' "$tok" > /var/lib/forgejo-mirror/token
      fi

      exec ${pkgs.bash}/bin/bash ${../scripts/forgejo-mirror.sh}
    '';
  };

  # daily repo discovery, forgejo fetches on MIRROR_INTERVAL
  systemd.timers.forgejo-mirror = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "30m";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 2222 ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.forgejo.sqlite = "/var/lib/forgejo/gitea/gitea.db";
}
