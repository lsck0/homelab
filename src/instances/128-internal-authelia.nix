{ config, pkgs, lib, ... }:
let
  stateDir = "/var/lib/authelia-main";

  # Runtime-generated config fragments. OIDC client secrets have to be stored
  # hashed, and a hash of a sops secret cannot be computed at build time
  # without leaking the secret into the world-readable Nix store.
  oidcClientsFile = "${stateDir}/oidc-clients.yml";
  ldapFile = "${stateDir}/ldap.yml";
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

  # State is on LOCAL disk, not the NAS. The auth gateway must not depend on
  # NFS: with a `hard` mount a NAS stall wedges authelia in uninterruptible
  # sleep (unkillable, port closed, 502 lab-wide), and with a `soft` mount the
  # sqlite store risks corruption. The state is small (TOTP enrolments,
  # sessions, generated keys) and a rebuild regenerates the keys.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 authelia-main authelia-main -"
  ];

  # Bind password for the lldap backend (same secret lldap itself uses).
  sops.secrets.lldap-admin-password = {};
  sops.secrets.nextcloud-oidc-secret = {};
  sops.secrets.vaultwarden-oidc-secret = {};
  sops.secrets.forgejo-oidc-secret = {};

  # Authelia's own cryptographic material is generated here rather than kept in
  # sops: none of it has to match anything outside this VM, and it persists on
  # local disk so a rebuild regenerates it (sessions and TOTP re-enrol).
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

      # lldap (vm-133) is the single identity store. The "lldap" implementation
      # preset fills in the correct filters/attributes; only the bind password
      # comes from the runtime fragment (ldapFile). Users and groups are managed
      # in lldap's admin dashboard.
      authentication_backend = {
        password_reset.disable = false;
        refresh_interval = "1m";
        ldap = {
          implementation = "lldap";
          address = "ldap://10.100.0.133:3890";
          base_dn = "dc=lsck0,dc=dev";
          user = "uid=admin,ou=people,dc=lsck0,dc=dev";
        };
      };

      # WebAuthn (FIDO2) is the strong second factor — a hardware key IS the
      # identity. Users enrol their key in the Authelia portal; internal services
      # then require it (two_factor).
      webauthn = {
        disable = false;
        display_name = "lsck0.dev";
        attestation_conveyance_preference = "indirect";
        timeout = "60s";
      };

      # Everything internal demands two_factor (lldap password + TOTP/FIDO2).
      # Single-user lab: any authenticated user is allowed — no group match
      # required (a group:admins rule that lldap didn't resolve caused a
      # deny→re-auth redirect loop). auth.lsck0.dev is bypassed to log in.
      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = [ "auth.lsck0.dev" ];
            policy = "bypass";
          }
          {
            domain = [ "*.lsck0.dev" "lsck0.dev" ];
            policy = "two_factor";
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
