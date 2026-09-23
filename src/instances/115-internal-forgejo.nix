{ config, pkgs, nasMount, retry, ... }: {
  networking.hostName = "vm-115";

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

      # The scopes are explicit because Forgejo asks for "openid" alone
      # otherwise, and an id_token with no profile and no email carries no
      # username and no address to create an account from. Auto-registration
      # then cannot run and the login lands on /user/link_account, which says
      # "Registration is disabled" because it is.
      # Errors are not sent to /dev/null: this step failing quietly is how the
      # source kept its one-scope configuration through several deploys.
      if [ -n "$AUTH_ID" ]; then
        echo "OAuth2 source exists (id=$AUTH_ID), updating..."
        podman exec -u git forgejo forgejo admin auth update-oauth \
          --id "$AUTH_ID" \
          --name authelia \
          --secret "$OIDC_SECRET" \
          --auto-discover-url "$DISCOVER_URL" \
          --scopes openid --scopes profile --scopes email \
          || echo "WARNING: could not update the authelia OAuth2 source"
        exit 0
      fi

      # create via Forgejo CLI inside container
      podman exec -u git forgejo forgejo admin auth add-oauth \
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

  # generate API token for Homepage widget
  systemd.services.forgejo-homepage-token = {
    description = "Generate Forgejo API token for Homepage";
    after = [ "podman-forgejo.service" "forgejo-oauth2-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman pkgs.gawk pkgs.coreutils ];
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
      # The CLI prints "Access token was successfully created: <token>", so the
      # value is the last field. It printed "... <token>" in some older
      # release, and the pattern that matched that one silently captured
      # nothing here for as long as this unit has existed - the token row was
      # created every boot and the file it feeds was never written, which is
      # why the Homepage widget had no Forgejo data. The name is stamped for
      # the same reason the mirror token's is: a duplicate is refused, so a
      # fixed name cannot be retried.
      TOKEN=$(podman exec -u git forgejo forgejo admin user generate-access-token \
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

  # ---- GitHub mirrors -------------------------------------------------------
  # GitHub stays the place repositories are pushed to; Forgejo keeps a pull
  # mirror of each one, so there is a second copy on hardware here that Kopia
  # snapshots with the rest of the NAS. The mirrors are read-only, so a broken
  # one can never leave GitHub stale.
  #
  # The token needs the `repo` scope, because the account has private
  # repositories and a mirror of only the public half is not a backup.
  sops.secrets.github-mirror-token = {};

  systemd.services.forgejo-mirror = {
    description = "Mirror every GitHub repository into Forgejo";
    after = [ "podman-forgejo.service" "forgejo-init.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.podman pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.bash ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "forgejo-mirror";
    };
    environment = {
      FORGEJO_OWNER = "luca";
      GITHUB_OWNER = "lsck0";
      # how often Forgejo re-fetches each mirror on its own
      MIRROR_INTERVAL = "8h";
      FORGEJO_TOKEN_FILE = "/var/lib/forgejo-mirror/token";
      GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
    };
    script = ''
      ${retry} 60 2 curl -sf http://127.0.0.1:80/api/healthz

      # A token of its own rather than the Homepage bot's: that one is
      # deliberately read-only, and creating a mirror is a write.
      #
      # The name carries a timestamp because Forgejo refuses a duplicate with
      # "access token name has been used already", and a run that creates the
      # token but fails to capture it would otherwise never be able to retry.
      # The value is the last field of "Access token was successfully
      # created: <token>", and it is checked before it is stored rather than
      # after: writing an empty file here is what makes every later run fail
      # on a name that is already taken.
      if [ ! -s /var/lib/forgejo-mirror/token ]; then
        out=$(podman exec -u git forgejo forgejo admin user generate-access-token \
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

  # Daily: Forgejo does the fetching itself on MIRROR_INTERVAL, so all this has
  # to catch is a repository that appeared on GitHub since the last run.
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
}
