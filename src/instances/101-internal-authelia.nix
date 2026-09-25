{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/authelia-main";

  # the access rules are generated from modules/routes.nix
  routes = (import ../modules/routes.nix).internal;
  ssoRoutes = lib.filterAttrs (_: r: (r.auth or "sso") == "sso") routes;
  routeRules = lib.concatLists (lib.mapAttrsToList (_: r: [
    {
      domain = [ "${r.host}.lsck0.dev" ];
      policy = "two_factor";
      subject = [ [ "group:${r.group or "users"}" ] ];
    }
    {
      domain = [ "${r.host}.lsck0.dev" ];
      policy = "deny";
    }
  ]) ssoRoutes);

  # runtime-generated config fragments.
  oidcClientsFile = "${stateDir}/oidc-clients.yml";
  ldapFile = "${stateDir}/ldap.yml";
  secretsDir = "${stateDir}/secrets";

  oidcClients = [
    {
      id = "forgejo";
      name = "Forgejo";
      secretName = "forgejo-oidc-secret";
      # Forgejo's go-oauth2 client posts the secret, verified against 7.0.16+gitea-1.21.11.
      tokenAuthMethod = "client_secret_post";
      # Forgejo derives the callback path from the auth source name.
      redirectUris = [
        "https://git.lsck0.dev/user/oauth2/authelia/callback"
        "https://git.lsck0.dev/user/oauth2/authentik/callback"
      ];
    }
    {
      id = "jellyfin";
      name = "Jellyfin";
      secretName = "jellyfin-oidc-secret";
      # jellyfin-plugin-sso posts the secret, as Authelia's own Jellyfin integration note says.
      tokenAuthMethod = "client_secret_post";
      redirectUris = [ "https://jellyfin.lsck0.dev/sso/OID/redirect/authelia" ];
    }
  ];

  # built line by line rather than as an indented block: Nix strips the common indentation
  mkClientYaml = c: lib.concatStringsSep "\n" ([
    "      - client_id: ${c.id}"
    "        client_name: ${c.name}"
    "        client_secret: '$CLIENT_HASH_${c.id}'"
    "        public: false"
    # same bar as the ForwardAuth routes: an OIDC login must not be a cheaper way into Forgejo
    "        authorization_policy: two_factor"
    "        require_pkce: false"
    "        consent_mode: implicit"
    # client_secret_basic is the OAuth 2.0 default and what Forgejo sends.
    "        token_endpoint_auth_method: ${c.tokenAuthMethod or "client_secret_basic"}"
    "        redirect_uris:"
  ] ++ map (u: "          - ${u}") c.redirectUris ++ [
    "        scopes:"
  ] ++ map (sc: "          - ${sc}") (c.scopes or [ "openid" "profile" "email" "groups" ]) ++ [
  ]) + "\n";
in {
  networking.hostName = "vm-101";

  # session store for Authelia, see session.redis below.
  services.redis.servers.authelia = {
    enable = true;
    port = 0;
    unixSocket = "/run/redis-authelia/redis.sock";
    unixSocketPerm = 660;
  };
  users.users.authelia-main.extraGroups = [ "redis-authelia" ];
  systemd.services.authelia-main.after = [ "redis-authelia.service" ];

  # state on LOCAL disk, not NFS: a NAS stall must not wedge the auth gateway. it's small
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 authelia-main authelia-main -"
  ];

  # ...but "a rebuild regenerates it" only covers the keys.
  homelab.dbBackup.databases.authelia.sqlite = "${stateDir}/db.sqlite3";

  # bind password for the lldap backend (same secret lldap itself uses).
  sops.secrets.lldap-admin-password = {};
  sops.secrets.forgejo-oidc-secret = {};
  sops.secrets.jellyfin-oidc-secret = {};

  # Authelia's own cryptographic material is generated here rather than kept in sops: none
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

      # --- LDAP bind password (kept out of the Nix store) ---
      LDAP_PASS=$(cat ${config.sops.secrets.lldap-admin-password.path})
      cat > ${ldapFile} <<EOF
      authentication_backend:
        ldap:
          password: "$LDAP_PASS"
      EOF

      # --- OIDC clients ---
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

      # lldap (vm-102) is the single identity store.
      authentication_backend = {
        password_reset.disable = false;
        refresh_interval = "1m";
        ldap = {
          implementation = "lldap";
          address = "ldap://10.100.0.102:3890";
          base_dn = "dc=lsck0,dc=dev";
          user = "uid=admin,ou=people,dc=lsck0,dc=dev";
        };
      };

      # WebAuthn (FIDO2) is the strong second factor: a hardware key IS the identity.
      webauthn = {
        disable = false;
        display_name = "lsck0.dev";
        attestation_conveyance_preference = "indirect";
        timeout = "60s";
      };

      # everything internal demands two_factor (lldap password + TOTP/FIDO2).
      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = [ "auth.lsck0.dev" ];
            policy = "bypass";
          }
        ] ++ routeRules ++ [
          # anything with a route but no entry in routes.nix
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

        # Without this Authelia keeps sessions in memory
        redis = {
          host = "/run/redis-authelia/redis.sock";
          port = 0;
        };
      };

      storage.local.path = "${stateDir}/db.sqlite3";

      # no SMTP in the lab, so password resets and 2FA enrolment links are written to a file
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
