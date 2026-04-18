{ pkgs, config, nasMount, ... }: {
  networking.hostName = "vm-112";

  # Resolve auth.internal directly to authentik VM (bypasses traefik)
  networking.hosts."10.100.0.101" = [ "auth.internal" ];

  fileSystems = nasMount "/var/lib/nextcloud" "nextcloud"
    // nasMount "/var/lib/postgresql" "nextcloud-db"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets.nextcloud-admin-pass.owner = "nextcloud";

  services.postgresql = {
    enable = true;
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [{
      name = "nextcloud";
      ensureDBOwnership = true;
    }];
  };

  services.nextcloud = {
    enable = true;
    hostName = "cloud.internal";
    config.dbtype = "pgsql";
    config.dbhost = "/run/postgresql";
    config.dbname = "nextcloud";
    config.adminpassFile = config.sops.secrets.nextcloud-admin-pass.path;
    package = pkgs.nextcloud33;
    database.createLocally = true;
    extraApps = {
      user_oidc = pkgs.fetchNextcloudApp {
        appName = "user_oidc";
        sha256 = "sha256-G8dxIpI4k3mlCtqYIwOUwHeJiMP08XOp9zM+BY/EWSo=";
        url = "https://github.com/nextcloud-releases/user_oidc/releases/download/v8.8.0/user_oidc-v8.8.0.tar.gz";
        appVersion = "8.8.0";
        license = "agpl3Plus";
      };
    };
    settings = {
      trusted_domains = [ "cloud.internal" "cloud.lsck0.dev" ];
      trusted_proxies = [ "10.100.0.100" ];
      overwriteprotocol = "https";
      overwritehost = "cloud.internal";
      allow_user_to_change_display_name = false;
      user_oidc = {
        single_logout = false;
      };
    };
  };

  # Configure OIDC provider after Nextcloud is set up
  systemd.services."nextcloud-oidc-setup" = {
    description = "Configure Nextcloud OIDC provider";
    after = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "nextcloud";
      ExecStart = pkgs.writeShellScript "nextcloud-oidc-setup" ''
        OCC="${config.services.nextcloud.occ}/bin/nextcloud-occ"

        # Enable the app
        $OCC app:enable user_oidc || true

        # Delete existing provider to ensure config is up to date
        $OCC user_oidc:provider:delete authentik 2>/dev/null || true

        $OCC user_oidc:provider authentik \
          --clientid="nextcloud" \
          --clientsecret="nextcloud-oidc-secret-changeme" \
          --discoveryuri="http://auth.internal/application/o/nextcloud/.well-known/openid-configuration" \
          --mapping-uid="preferred_username" \
          --mapping-display-name="name" \
          --mapping-email="email" \
          --unique-uid=1 || true
      '';
    };
  };

  systemd.services."nextcloud-setup" = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };

  # Export admin credentials for Homepage widget
  systemd.services.nextcloud-homepage-token = {
    description = "Export Nextcloud credentials for Homepage";
    after = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      [ -f /var/lib/homepage-tokens/nextcloud-user.token ] && exit 0
      echo -n "admin" > /var/lib/homepage-tokens/nextcloud-user.token
      tr -d '\n' < ${config.sops.secrets.nextcloud-admin-pass.path} > /var/lib/homepage-tokens/nextcloud-pass.token
      chmod 644 /var/lib/homepage-tokens/nextcloud-user.token /var/lib/homepage-tokens/nextcloud-pass.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
