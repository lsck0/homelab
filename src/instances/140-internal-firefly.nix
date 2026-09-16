{ config, pkgs, nasMount, ... }: {
  networking.hostName = "vm-140";

  # Firefly III — self-hosted personal finance (item 14, alongside Actual).
  # App + its own Postgres, both containers on this VM; data on the NAS so it is
  # backed up. Behind Authelia at firefly.lsck0.dev.
  fileSystems = nasMount "/var/lib/firefly" "firefly";

  sops.secrets.firefly-app-key = {};
  sops.secrets.firefly-db-password = {};
  sops.templates."firefly.env".content = ''
    APP_KEY=${config.sops.placeholder.firefly-app-key}
    DB_CONNECTION=pgsql
    DB_HOST=127.0.0.1
    DB_PORT=5432
    DB_DATABASE=firefly
    DB_USERNAME=firefly
    DB_PASSWORD=${config.sops.placeholder.firefly-db-password}
    APP_URL=https://firefly.lsck0.dev
    TRUSTED_PROXIES=*
  '';
  sops.templates."firefly-db.env".content = ''
    POSTGRES_DB=firefly
    POSTGRES_USER=firefly
    POSTGRES_PASSWORD=${config.sops.placeholder.firefly-db-password}
  '';

  virtualisation.oci-containers.containers = {
    firefly-db = {
      image = "docker.io/library/postgres:16-alpine";
      volumes = [ "/var/lib/firefly/db:/var/lib/postgresql/data" ];
      environmentFiles = [ config.sops.templates."firefly-db.env".path ];
      extraOptions = [ "--network=host" ];
    };
    firefly = {
      image = "docker.io/fireflyiii/core:latest";
      dependsOn = [ "firefly-db" ];
      # host network: firefly listens on :8080, reaches postgres on 127.0.0.1:5432.
      volumes = [ "/var/lib/firefly/upload:/var/www/html/storage/upload" ];
      environmentFiles = [ config.sops.templates."firefly.env".path ];
      extraOptions = [ "--network=host" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/firefly 0750 1000 1000 -"
    "d /var/lib/firefly/db 0750 999 999 -"
    "d /var/lib/firefly/upload 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
