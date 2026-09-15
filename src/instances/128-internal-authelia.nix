{ config, pkgs, lib, nasMount, ... }:
let
  stateDir = "/var/lib/authelia-main";
  adminUser = "luca";

  # Runtime-generated config fragments. OIDC client secrets have to be stored
  # hashed, and a hash of a sops secret cannot be computed at build time
  # without leaking the secret into the world-readable Nix store.
  oidcClientsFile = "${stateDir}/oidc-clients.yml";
  usersFile = "${stateDir}/users_database.yml";
  secretsDir = "${stateDir}/secrets";

  oidcClients = [
    {
      id = "nextcloud";
      name = "Nextcloud";
      secretName = "nextcloud-oidc-secret";
      redirectUris = [ "https://cloud.lsck0.dev/apps/user_oidc/code" ];
    }
    {
      id = "vaultwarden";
      name = "Vaultwarden";
      secretName = "vaultwarden-oidc-secret";
      redirectUris = [ "https://vault.lsck0.dev/identity/connect/oidc-signin" ];
    }
    {
      id = "forgejo";
      name = "Forgejo";
      secretName = "forgejo-oidc-secret";
      # Forgejo derives the callback path from the auth source name, so both
      # the existing authentik source and a new authelia one are accepted.
      redirectUris = [
        "https://git.lsck0.dev/user/oauth2/authelia/callback"
        "https://git.lsck0.dev/user/oauth2/authentik/callback"
      ];
    }
  ];

  # Built line by line rather than as an indented block: Nix strips the common
  # indentation from '' strings, which silently flattens nested YAML.
  mkClientYaml = c: lib.concatStringsSep "\n" ([
    "      - client_id: ${c.id}"
    "        client_name: ${c.name}"
    "        client_secret: '$CLIENT_HASH_${c.id}'"
    "        public: false"
    "        authorization_policy: one_factor"
    "        require_pkce: false"
    "        consent_mode: implicit"
    "        token_endpoint_auth_method: client_secret_post"
    "        redirect_uris:"
  ] ++ map (u: "          - ${u}") c.redirectUris ++ [
    "        scopes:"
    "          - openid"
    "          - profile"
    "          - email"
    "          - groups"
  ]) + "\n";
in {
  networking.hostName = "vm-128";

  fileSystems = nasMount stateDir "authelia";

  sops.secrets.authelia-admin-pass = {};
  sops.secrets.nextcloud-oidc-secret = {};
  sops.secrets.vaultwarden-oidc-secret = {};
  sops.secrets.forgejo-oidc-secret = {};

  # Authelia's own cryptographic material is generated here rather than kept in
  # sops: none of it has to match anything outside this VM, and it persists on
  # the NAS so a rebuild does not invalidate existing sessions and TOTP enrolments.
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

      # --- users database ---
      ADMIN_PASS=$(cat ${config.sops.secrets.authelia-admin-pass.path})
      ADMIN_HASH=$(authelia crypto hash generate argon2 --password "$ADMIN_PASS" --no-confirm \
        | sed -n 's/^Digest: //p')
      [ -n "$ADMIN_HASH" ] || { echo "Failed to hash admin password"; exit 1; }

      cat > ${usersFile} <<EOF
      users:
        ${adminUser}:
          disabled: false
          displayname: "Luca"
          password: "$ADMIN_HASH"
          email: ${config.homelab.acmeEmail}
          groups:
            - admins
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

    settingsFiles = [ oidcClientsFile ];

    settings = {
      theme = "dark";
      server.address = "tcp://0.0.0.0:9091/";
      log.level = "info";
      log.format = "text";

      authentication_backend = {
        password_reset.disable = true;
        # No LDAP, no database: a single YAML file the bootstrap unit writes.
        file = {
          path = usersFile;
          watch = true;
        };
      };

      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = [ "*.lsck0.dev" "lsck0.dev" ];
            policy = "one_factor";
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
          authelia_url = "https://auth2.lsck0.dev";
          default_redirection_url = "https://homepage.lsck0.dev";
        }];
      };

      storage.local.path = "${stateDir}/db.sqlite3";

      # No SMTP in the lab, so password resets and 2FA enrolment links are
      # written to a file on the VM instead of being mailed.
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
