# authelia: forwardauth for every sso route on the internal ingress and the lab's oidc provider, over lldap
#
# Every secret comes from sops: authelia's own through its *File options, the ldap bind password through
# AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE, the oidc client secrets through the template filter's
# `{{ secret "<file>" }}`. The configuration is rendered from nix alone; no script writes yaml or holds a secret.
{ config, lib, inventory, site, catalog, lab, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  user = "authelia-main";
  # local disk: nas stalls must not wedge auth
  stateDir = "/var/lib/authelia-main";
  dbFile = "${stateDir}/db.sqlite3";
  redisSocket = "/run/redis-authelia/redis.sock";
  url = host: "https://${net.fqdn host}";
  portal = catalog.internal.authelia;
  routes = catalog.internal // catalog.external;

  # admins reach everything, anyone else needs the page's or the client's own group (lldap creates them all)
  adminsSubject = "group:${catalog.access.admins}";
  appSubject = name: "group:${catalog.access.groups.${name}}";

  # access rules come from every route behind sso, either ingress: nixos services and swarm apps (modules/catalog.nix)
  ssoRoutes = lib.filterAttrs (_: r: r.off.sso == null) routes;
  routeRules = lib.concatLists (lib.mapAttrsToList (name: r: let domain = [ (net.fqdn r.host) ]; in [
    {
      inherit domain;
      policy = "two_factor";
      subject = [ [ adminsSubject ] [ (appSubject name) ] ];
    }
    {
      inherit domain;
      policy = "deny";
    }
  ]) ssoRoutes);

  # every oidc client an instance declares (instance.nix `oidc`), its secret read at start by the template filter
  oidcClients = map (c: {
    inherit (c) id name tokenAuthMethod pkce;
    secretName = c.secret;
    redirectUris = [ "${url routes.${c.route}.host}${c.callback}" ];
  }) lab.oidc;
in {
  imports = [ ./lib/lldap.nix ];

  networking.hostName = "vm-101";

  # authelia session store
  services.redis.servers.authelia = {
    enable = true;
    port = 0;
    unixSocket = redisSocket;
    unixSocketPerm = 660;
  };
  users.users.${user}.extraGroups = [ "redis-authelia" ];
  # binds to lldap on start
  systemd.services.authelia-main.after = [ "redis-authelia.service" "lldap.service" "lldap-bootstrap.service" ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 ${user} ${user} -"
  ];

  homelab.dbBackup.databases.authelia.sqlite = dbFile;

  sops.secrets = lib.genAttrs ([
    "authelia-jwt-secret"
    "authelia-storage-key"
    "authelia-session-secret"
    "authelia-oidc-hmac"
    "authelia-oidc-issuer-key"
    # lib/lldap.nix sets the read-only bind user's password from it
    "lldap-authelia-bind-password"
  ] ++ map (c: c.secretName) oidcClients) (_: { owner = user; });

  services.authelia.instances.main = {
    enable = true;

    # in sops, not generated here: the storage key decrypts the 2fa data in the db dumps
    secrets = {
      jwtSecretFile = config.sops.secrets.authelia-jwt-secret.path;
      storageEncryptionKeyFile = config.sops.secrets.authelia-storage-key.path;
      sessionSecretFile = config.sops.secrets.authelia-session-secret.path;
      oidcHmacSecretFile = config.sops.secrets.authelia-oidc-hmac.path;
      oidcIssuerPrivateKeyFile = config.sops.secrets.authelia-oidc-issuer-key.path;
    };

    environmentVariables = {
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE = config.sops.secrets.lldap-authelia-bind-password.path;
      X_AUTHELIA_CONFIG_FILTERS = "template";
    };

    settings = {
      theme = "dark";
      # every caller is the internal ingress or a granted prober (homelab.ingressOnly below, modules/flows.nix)
      server.address = "tcp://0.0.0.0:${toString portal.port}/";
      log.level = "info";
      log.format = "text";

      authentication_backend = {
        # the notifier is a file nobody reads and the bind user may not write: a reset could never complete
        password_reset.disable = true;
        # 5m: 1m queued binds behind homepage's pings
        refresh_interval = "5m";
        ldap = {
          implementation = "lldap";
          address = "ldap://127.0.0.1:${toString config.services.lldap.settings.ldap_port}";
          base_dn = net.domainDn;
          # read only (lldap_strict_readonly, lib/lldap.nix): authelia only looks users up and checks passwords
          user = "uid=authelia-bind,ou=people,${net.domainDn}";
        };
      };

      # oidc must not be a cheaper way in: the client's own app group, or admins, as for forwardauth
      identity_providers.oidc = {
        authorization_policies = lib.listToAttrs (map (c: lib.nameValuePair c.id {
          default_policy = "deny";
          rules = [{ policy = "two_factor"; subject = [ adminsSubject (appSubject c.id) ]; }];
        }) oidcClients);
        clients = map (c: {
          client_id = c.id;
          client_name = c.name;
          # compared in constant time; the sops file is its only copy
          client_secret = "$plaintext$" + "{{ secret \"${config.sops.secrets.${c.secretName}.path}\" }}";
          public = false;
          authorization_policy = c.id;
          require_pkce = c.pkce;
          consent_mode = "implicit";
          token_endpoint_auth_method = c.tokenAuthMethod;
          redirect_uris = c.redirectUris;
          scopes = [ "openid" "profile" "email" "groups" ];
        } // lib.optionalAttrs c.pkce { pkce_challenge_method = "S256"; }) oidcClients;
      };

      webauthn = {
        disable = false;
        display_name = net.domain;
        attestation_conveyance_preference = "indirect";
        timeout = "60s";
      };

      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = [ (net.fqdn portal.host) ];
            policy = "bypass";
          }
        ] ++ routeRules ++ [
          # hosts no route names
          {
            domain = [ "*.${net.domain}" net.domain ];
            policy = "two_factor";
            subject = [ [ adminsSubject ] ];
          }
        ];
      };

      session = {
        name = "authelia_session";
        expiration = "12h";
        inactivity = "45m";
        remember_me = "1M";
        cookies = [{
          inherit (net) domain;
          authelia_url = url portal.host;
          default_redirection_url = url catalog.internal.homepage.host;
        }];

        # else sessions live in memory
        redis = {
          host = redisSocket;
          port = 0;
        };
      };

      storage.local.path = dbFile;

      # no smtp, notifications (the identity verification codes) go to a file
      notifier = {
        disable_startup_check = true;
        filesystem.filename = "${stateDir}/notification.txt";
      };

      regulation = {
        max_retries = 3;
        find_time = "2m";
        ban_time = "5m";
      };

      totp.issuer = net.domain;
    };
  };

  networking.firewall.allowedTCPPorts = [ portal.port ];
  # regulation counts per user: a lan device calling the portal directly could lock the admin out unseen by the
  # ingress's crowdsec and limits
  homelab.ingressOnly.ports = [ portal.port ];
}
