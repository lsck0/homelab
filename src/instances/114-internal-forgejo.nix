{ config, pkgs, nasMount, retry, ... }: {
  networking.hostName = "vm-114";

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
      # SSO-only: no self-service signup, and nothing is visible without logging
      # in (kills anonymous browsing). Accounts are created only by the Authelia
      # OAuth source (auto-register); the local login form stays only as a
      # break-glass admin. Basic-auth git-over-HTTP is disabled: use SSH or a
      # personal access token.
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

  # create the initial admin user if Forgejo has no users yet.
  # idempotent: exits immediately if any user already exists.
  # password retrieved from SOPS; login via Authelia SSO is the normal path.
  systemd.services.forgejo-init = {
    description = "Initialise Forgejo admin user";
    after = [ "podman-forgejo.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      # skip if users already exist
      COUNT=$(podman exec -u git forgejo forgejo admin user list 2>/dev/null | grep -c '^[0-9]' || echo 0)
      [ "$COUNT" -gt 0 ] && { echo "Users exist ($COUNT), skipping init"; exit 0; }

      PASS=$(cat ${config.sops.secrets.forgejo-admin-pass.path})
      podman exec -u git forgejo forgejo admin user create \
        --admin \
        --username luca \
        --password "$PASS" \
        --email luca.sandrock@proton.me \
        --must-change-password=false
      echo "Admin user created"
    '';
  };

  # configure OAuth2 auth source after Forgejo starts and is initialised
  systemd.services.forgejo-oauth2-setup = {
    description = "Configure Forgejo OAuth2 with Authelia";
    after = [ "podman-forgejo.service" "forgejo-init.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman pkgs.gawk pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      OIDC_SECRET=$(cat ${config.sops.secrets.forgejo-oidc-secret.path})
      DISCOVER_URL="https://auth.lsck0.dev/.well-known/openid-configuration"

      # The sign-in button is labelled with the auth source's name, which is why
      # the login page used to say "authentik" long after Authelia replaced it.
      # Forgejo also derives the callback path from that name, so a rename would
      # normally invalidate the redirect URI: Authelia has both
      # /user/oauth2/{authelia,authentik}/callback registered
      # (101-internal-authelia.nix), so renaming the source in place is safe and
      # keeps every already-linked account working.
      sources=$(podman exec -u git forgejo forgejo admin auth list 2>/dev/null || true)
      AUTH_ID=$(echo "$sources" | grep -w authelia  | awk '{print $1}')
      OLD_ID=$(echo "$sources"  | grep -w authentik | awk '{print $1}')

      if [ -z "$AUTH_ID" ] && [ -n "$OLD_ID" ]; then
        echo "renaming the authentik OAuth2 source to authelia (id=$OLD_ID)"
        AUTH_ID="$OLD_ID"
        podman exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" --name authelia || true
      fi

      if [ -n "$AUTH_ID" ]; then
        echo "OAuth2 source exists (id=$AUTH_ID), updating..."
        podman exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" \
          --name authelia \
          --secret "$OIDC_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          2>/dev/null || true
        exit 0
      fi

      # create via Forgejo CLI inside container
      podman exec -u git forgejo forgejo admin auth add-oauth \
        --name authelia \
        --provider openidConnect \
        --key forgejo \
        --secret "$OIDC_SECRET" \
        --auto-discover-url "$DISCOVER_URL" \
        --skip-local-2fa \
        2>/dev/null || echo "Auth source may already exist"
    '';
  };

  # generate API token for Homepage widget
  systemd.services.forgejo-homepage-token = {
    description = "Generate Forgejo API token for Homepage";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      TOKEN_FILE="/var/lib/homepage-tokens/forgejo-key.token"

      # check existing token validity; only clear on explicit 401 (stale), not network errors
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

      # create a local bot user for API access
      podman exec -u git forgejo forgejo admin user create \
        --username homepage-bot \
        --password "homepage-bot-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
        --email homepage@lsck0.dev \
        --must-change-password=false 2>/dev/null || true

      # generate token with required scopes (skip if already exists)
      TOKEN=$(podman exec -u git forgejo forgejo admin user generate-access-token \
        --username homepage-bot \
        --token-name homepage \
        --scopes read:activitypub,read:issue,read:misc,read:notification,read:organization,read:package,read:repository,read:user \
        2>/dev/null | grep -oP 'Access token was successfully created\.\.\. \K.*' || true)

      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > "$TOKEN_FILE"
        echo "Forgejo Homepage token created"
      else
        echo "Token may already exist or creation failed"
      fi
    '';
  };

  # generate runner registration token and save to NAS for runner VM
  systemd.services.forgejo-runner-token = {
    description = "Generate Forgejo runner registration token";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.podman ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${retry} 60 2 podman exec -u git forgejo forgejo admin user list

      # always regenerate token (they're one-use for registration)
      TOKEN=$(podman exec -u git forgejo forgejo actions generate-runner-token 2>/dev/null || true)
      if [ -n "$TOKEN" ]; then
        echo -n "$TOKEN" > /var/lib/homepage-tokens/forgejo-runner.token
        echo "Runner token generated"
      fi
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 2222 ];
}
