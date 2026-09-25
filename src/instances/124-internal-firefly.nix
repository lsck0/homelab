{ config, pkgs, nasMount, ... }: {
  networking.hostName = "vm-124";

  # Firefly III: self-hosted personal finance. app + its own Postgres
  fileSystems = nasMount "/var/lib/firefly" "firefly"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

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
      image = "docker.io/library/postgres:16.15-alpine";
      volumes = [ "/var/lib/firefly/db:/var/lib/postgresql/data" ];
      environmentFiles = [ config.sops.templates."firefly-db.env".path ];
      extraOptions = [ "--network=host" ];
    };
    firefly = {
      image = "docker.io/fireflyiii/core:version-6.7.2";
      dependsOn = [ "firefly-db" ];
      # host network: firefly listens on :8080, reaches postgres on 127.0.0.1:5432.
      volumes = [ "/var/lib/firefly/upload:/var/www/html/storage/upload" ];
      environmentFiles = [ config.sops.templates."firefly.env".path ];
      extraOptions = [ "--network=host" ];
    };
  };

  # /var/lib/firefly/db is a live Postgres data directory on the NAS.
  homelab.dbBackup.databases.firefly = {
    command = "podman exec firefly-db pg_dump -U firefly --clean --if-exists firefly";
    path = [ pkgs.podman ];
  };

  # personal access token for Hermes (logs bills as transactions).
  systemd.services.firefly-hermes-token = {
    description = "Export a Firefly III API token for Hermes";
    after = [ "podman-firefly.service" ];
    path = [ pkgs.podman pkgs.coreutils pkgs.gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=/var/lib/homepage-tokens/firefly-token.token
      [ -s "$out" ] && exit 0
      tinker() { podman exec firefly php artisan tinker --execute="$1" 2>/dev/null | tail -1; }
      [ "$(tinker 'echo \FireflyIII\User::count();')" -gt 0 ] 2>/dev/null || { echo "no Firefly user yet"; exit 0; }
      podman exec firefly php artisan passport:client --personal --no-interaction --name=homelab >/dev/null 2>&1 || true
      token=$(tinker 'echo \FireflyIII\User::orderBy("id")->first()->createToken("hermes")->accessToken;')
      echo "$token" | grep -q '^ey' || { echo "token creation failed: $token"; exit 1; }
      echo -n "$token" > "$out"
    '';
  };
  systemd.timers.firefly-hermes-token = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "30m"; };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/firefly 0750 1000 1000 -"
    # 70, not 999: postgres:*-alpine runs as uid 70.
    "d /var/lib/firefly/db 0750 70 70 -"
    "d /var/lib/firefly/upload 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
