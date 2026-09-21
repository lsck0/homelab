{ config, pkgs, nasMount, nasPath, retry, ... }: {
  networking.hostName = "vm-135";

  # Audiobookshelf signs in through Authelia (OIDC client in
  # 101-internal-authelia.nix), so the account is the lldap one and there is no
  # second password to remember. Local login stays enabled as a break-glass
  # path: ForwardAuth is not usable here because the mobile apps cannot follow
  # the portal redirect.
  sops.secrets.audiobookshelf-oidc-secret = {};

  fileSystems = nasMount "/var/lib/audiobookshelf" "audiobookshelf"
    // nasPath "/srv/audiobooks" "media/audiobooks"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # Bookshelf (maintained Readarr fork, Hardcover metadata): ebook manager.
  # downloads into /data/media/books, which Kavita serves. Wired by vm-133.
  homelab.servarr.bookshelf = {
    image = "ghcr.io/pennydreadful/bookshelf:hardcover-v0.4.21.182";
    port = 8787;
    hostPort = 8787;
  };

  virtualisation.oci-containers.containers.audiobookshelf = {
    image = "ghcr.io/advplyr/audiobookshelf:2.36.1";
    ports = [ "80:80" ];
    volumes = [
      "/srv/audiobooks:/audiobooks"
      "/var/lib/audiobookshelf/config:/config"
      "/var/lib/audiobookshelf/metadata:/metadata"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/audiobookshelf/config 0750 1000 1000 -"
    "d /var/lib/audiobookshelf/metadata 0750 1000 1000 -"
  ];

  # admin with a generated password, and its API token for the Homepage widget
  systemd.services.audiobookshelf-homepage-token = {
    description = "Initialise Audiobookshelf admin and export its API token for Homepage";
    after = [ "podman-audiobookshelf.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      A=http://127.0.0.1:80
      T=/var/lib/homepage-tokens
      ${retry} 90 2 curl -sf $A/healthcheck

      [ -s $T/audiobookshelf-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/audiobookshelf-pass.token
      PASS=$(cat $T/audiobookshelf-pass.token)
      json() { jq -cn --arg p "$1" "$2"; }
      login() { # password
        curl -sf -X POST $A/login -H "Content-Type: application/json" \
          -d "$(json "$1" '{username:"admin", password:$p}')" | jq -r '.user.token // empty'
      }

      if curl -sf $A/status | jq -e '.isInit == false' >/dev/null; then
        curl -sf -X POST $A/init -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{newRoot:{username:"admin", password:$p}}')"
      fi

      TOKEN=$(login "$PASS")
      # installs from before generated passwords still have admin/admin.
      if [ -z "$TOKEN" ] && OLD=$(login admin) && [ -n "$OLD" ]; then
        curl -sf -X PATCH $A/api/me/password -H "Authorization: Bearer $OLD" -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{password:"admin", newPassword:$p}')"
        TOKEN=$(login "$PASS")
        echo "admin moved off the default password"
      fi
      [ -n "$TOKEN" ] || { echo "Audiobookshelf admin login failed"; exit 1; }
      echo -n "$TOKEN" > $T/audiobookshelf-key.token

      # point the OpenID login at Authelia. Endpoints are spelled out rather
      # than discovered because Audiobookshelf stores them individually.
      SECRET=$(cat ${config.sops.secrets.audiobookshelf-oidc-secret.path})
      curl -sf -X PATCH $A/api/auth-settings \
        -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
        -d "$(jq -cn --arg s "$SECRET" '{
          authActiveAuthMethods: ["local", "openid"],
          authOpenIDIssuerURL: "https://auth.lsck0.dev",
          authOpenIDAuthorizationURL: "https://auth.lsck0.dev/api/oidc/authorization",
          authOpenIDTokenURL: "https://auth.lsck0.dev/api/oidc/token",
          authOpenIDUserInfoURL: "https://auth.lsck0.dev/api/oidc/userinfo",
          authOpenIDJwksURL: "https://auth.lsck0.dev/jwks.json",
          authOpenIDLogoutURL: "https://auth.lsck0.dev/logout",
          authOpenIDClientID: "audiobookshelf",
          authOpenIDClientSecret: $s,
          authOpenIDButtonText: "Sign in with Authelia",
          authOpenIDAutoLaunch: true,
          authOpenIDAutoRegister: true,
          authOpenIDMatchExistingBy: "username",
          authOpenIDSubfolderForRedirectURLs: ""
        }')" >/dev/null \
        && echo "Audiobookshelf OpenID pointed at Authelia" \
        || echo "Audiobookshelf OpenID setup failed; local login still works"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
