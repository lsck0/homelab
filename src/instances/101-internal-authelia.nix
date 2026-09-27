{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/authelia-main";

  # access rules come from modules/routes.nix
  routes = (import ../modules/routes.nix).internal;
  ssoRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes;
  # admins, app-<route> group, or bundle group
  routeSubjects = name: r: lib.unique [ [ "group:admins" ] [ "group:app-${name}" ] [ "group:${r.group or "users"}" ] ];
  routeRules = lib.concatLists (lib.mapAttrsToList (name: r: [
    {
      domain = [ "${r.host}.lsck0.dev" ];
      policy = "two_factor";
      subject = routeSubjects name r;
    }
    {
      domain = [ "${r.host}.lsck0.dev" ];
      policy = "deny";
    }
  ]) ssoRoutes);

  # runtime-generated config fragments
  oidcClientsFile = "${stateDir}/oidc-clients.yml";
  ldapFile = "${stateDir}/ldap.yml";
  secretsDir = "${stateDir}/secrets";

  oidcClients = [
    {
      id = "forgejo";
      name = "Forgejo";
      secretName = "forgejo-oidc-secret";
      # forgejo posts the secret (7.0.16+gitea-1.21.11)
      tokenAuthMethod = "client_secret_post";
      # callback path follows the forgejo source name
      redirectUris = [
        "https://git.lsck0.dev/user/oauth2/authelia/callback"
        "https://git.lsck0.dev/user/oauth2/authentik/callback"
      ];
    }
    {
      id = "jellyfin";
      name = "Jellyfin";
      secretName = "jellyfin-oidc-secret";
      # jellyfin-plugin-sso posts the secret
      tokenAuthMethod = "client_secret_post";
      redirectUris = [ "https://jellyfin.lsck0.dev/sso/OID/redirect/authelia" ];
    }
    {
      id = "headplane";
      name = "Headplane";
      secretName = "headplane-oidc-secret";
      tokenAuthMethod = "client_secret_post";
      redirectUris = [ "https://hs-ui.lsck0.dev/admin/oidc/callback" ];
    }
  ];

  # oidc obeys the forwardauth groups
  mkPolicyYaml = c: lib.concatStringsSep "\n" [
    "        ${c.id}:"
    "          default_policy: deny"
    "          rules:"
    "            - policy: two_factor"
    "              subject: ['group:admins', 'group:app-${c.id}']"
  ] + "\n";

  # line by line, nix strips common indentation
  mkClientYaml = c: lib.concatStringsSep "\n" ([
    "      - client_id: ${c.id}"
    "        client_name: ${c.name}"
    "        client_secret: '$CLIENT_HASH_${c.id}'"
    "        public: false"
    # oidc must not be a cheaper way in
    "        authorization_policy: ${c.id}"
    "        require_pkce: false"
    "        consent_mode: implicit"
    # client_secret_basic is the oauth 2.0 default
    "        token_endpoint_auth_method: ${c.tokenAuthMethod or "client_secret_basic"}"
    "        redirect_uris:"
  ] ++ map (u: "          - ${u}") c.redirectUris ++ [
    "        scopes:"
  ] ++ map (sc: "          - ${sc}") (c.scopes or [ "openid" "profile" "email" "groups" ]) ++ [
  ]) + "\n";
in {
  networking.hostName = "vm-101";

  # authelia session store
  services.redis.servers.authelia = {
    enable = true;
    port = 0;
    unixSocket = "/run/redis-authelia/redis.sock";
    unixSocketPerm = 660;
  };
  users.users.authelia-main.extraGroups = [ "redis-authelia" ];
  systemd.services.authelia-main.after = [ "redis-authelia.service" ];

  # local disk: nas stalls must not wedge auth
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 authelia-main authelia-main -"
  ];

  # db is backed up, only keys regenerate
  homelab.dbBackup.databases.authelia.sqlite = "${stateDir}/db.sqlite3";

  # lldap bind password, shared with lldap
  sops.secrets.lldap-admin-password = {};
  sops.secrets.forgejo-oidc-secret = {};
  sops.secrets.jellyfin-oidc-secret = {};
  sops.secrets.headplane-oidc-secret = {};

  # own crypto generated here, not in sops
  systemd.services.authelia-bootstrap = {
    description = "Generate Authelia secrets, users and OIDC clients";
    before = [ "authelia-main.service" ];
    requiredBy = [ "authelia-main.service" ];
    path = [ pkgs.openssl pkgs.authelia pkgs.coreutils pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      umask 077
      mkdir -p ${secretsDir}

      gen_hex() {
        [ -s "$1" ] || openssl rand -hex 32 | tr -d '\n' > "$1"
      }
      gen_hex ${secretsDir}/jwt
      gen_hex ${secretsDir}/storage-encryption-key
      gen_hex ${secretsDir}/session
      gen_hex ${secretsDir}/oidc-hmac

      if [ ! -s ${secretsDir}/oidc-issuer.pem ]; then
        openssl genrsa -out ${secretsDir}/oidc-issuer.pem 4096
      fi

      # --- ldap bind password, out of the store ---
      LDAP_PASS=$(cat ${config.sops.secrets.lldap-admin-password.path})
      cat > ${ldapFile} <<EOF
      authentication_backend:
        ldap:
          password: "$LDAP_PASS"
      EOF

      # --- oidc clients ---
      hash_secret() {
        authelia crypto hash generate pbkdf2 --variant sha512 --password "$1" --no-confirm \
          | sed -n 's/^Digest: //p'
      }
      ${lib.concatMapStrings (c: ''
        CLIENT_HASH_${c.id}=$(hash_secret "$(cat ${config.sops.secrets.${c.secretName}.path})")
        [ -n "$CLIENT_HASH_${c.id}" ] || { echo "Failed to hash ${c.id} client secret"; exit 1; }
      '') oidcClients}

      cat > ${oidcClientsFile} <<EOF
      identity_providers:
        oidc:
          authorization_policies:
      ${lib.concatMapStrings mkPolicyYaml oidcClients}
          clients:
      ${lib.concatMapStrings mkClientYaml oidcClients}
      EOF

      chown -R authelia-main:authelia-main ${stateDir}
      chmod 700 ${secretsDir}
    '';
  };

  services.authelia.instances.main = {
    enable = true;

    secrets = {
      jwtSecretFile = "${secretsDir}/jwt";
      storageEncryptionKeyFile = "${secretsDir}/storage-encryption-key";
      sessionSecretFile = "${secretsDir}/session";
      oidcHmacSecretFile = "${secretsDir}/oidc-hmac";
      oidcIssuerPrivateKeyFile = "${secretsDir}/oidc-issuer.pem";
    };

    settingsFiles = [ oidcClientsFile ldapFile ];

    settings = {
      theme = "dark";
      server.address = "tcp://0.0.0.0:9091/";
      log.level = "info";
      log.format = "text";

      # lldap (vm-102) is the identity store
      authentication_backend = {
        password_reset.disable = false;
        # 5m: 1m queued binds behind homepage's pings
        refresh_interval = "5m";
        ldap = {
          implementation = "lldap";
          address = "ldap://10.100.0.102:3890";
          base_dn = "dc=lsck0,dc=dev";
          user = "uid=admin,ou=people,dc=lsck0,dc=dev";
          pooling = { enable = true; count = 8; retries = 2; timeout = "10s"; };
        };
      };

      # webauthn: hardware key as second factor
      webauthn = {
        disable = false;
        display_name = "lsck0.dev";
        attestation_conveyance_preference = "indirect";
        timeout = "60s";
      };

      # internal routes demand two_factor
      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = [ "auth.lsck0.dev" ];
            policy = "bypass";
          }
        ] ++ routeRules ++ [
          # routes missing from routes.nix
          {
            domain = [ "*.lsck0.dev" "lsck0.dev" ];
            policy = "two_factor";
            subject = [ [ "group:admins" ] ];
          }
        ];
      };

      session = {
        name = "authelia_session";
        expiration = "12h";
        inactivity = "45m";
        remember_me = "1M";
        cookies = [{
          domain = "lsck0.dev";
          authelia_url = "https://auth.lsck0.dev";
          default_redirection_url = "https://homepage.lsck0.dev";
        }];

        # else sessions live in memory
        redis = {
          host = "/run/redis-authelia/redis.sock";
          port = 0;
        };
      };

      storage.local.path = "${stateDir}/db.sqlite3";

      # no smtp, notifications go to a file
      notifier = {
        disable_startup_check = true;
        filesystem.filename = "${stateDir}/notification.txt";
      };

      regulation = {
        max_retries = 3;
        find_time = "2m";
        ban_time = "5m";
      };

      totp.issuer = "lsck0.dev";
    };
  };

  networking.firewall.allowedTCPPorts = [ 9091 ];
}
