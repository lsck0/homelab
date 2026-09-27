{ config, pkgs, nasMount, ... }: {
  networking.hostName = "vm-124";

  # firefly iii with its own postgres
  fileSystems = nasMount "/var/lib/firefly" "firefly"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets.firefly-app-key = {};
  sops.secrets.firefly-db-password = {};
  sops.templates."firefly.env".restartUnits = [ "podman-firefly.service" ];
  systemd.services.podman-firefly.restartTriggers = [ config.sops.templates."firefly.env".content ];
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
    # login via authelia's Remote-Email
    AUTHENTICATION_GUARD=remote_user_guard
    AUTHENTICATION_GUARD_HEADER=HTTP_REMOTE_EMAIL
    AUTHENTICATION_GUARD_EMAIL=HTTP_REMOTE_EMAIL
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
      # host network: :8080, postgres on 127.0.0.1:5432
      volumes = [ "/var/lib/firefly/upload:/var/www/html/storage/upload" ];
      environmentFiles = [ config.sops.templates."firefly.env".path ];
      extraOptions = [ "--network=host" ];
    };
  };

  # dump, the nas holds a live data dir
  homelab.dbBackup.databases.firefly = {
    command = "podman exec firefly-db pg_dump -U firefly --clean --if-exists firefly";
    path = [ pkgs.podman ];
  };

  # hermes token for logging bills
  systemd.services.firefly-hermes-token = {
    description = "Export a Firefly III API token for Hermes";
    after = [ "podman-firefly.service" ];
    path = [ pkgs.podman pkgs.coreutils pkgs.gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=/var/lib/homepage-tokens/firefly-token.token
      tinker() { podman exec firefly php artisan tinker --execute="$1" 2>/dev/null | tail -1; }
      [ "$(tinker 'echo \FireflyIII\User::count();')" -gt 0 ] 2>/dev/null || { echo "no Firefly user yet"; exit 0; }
      # header login matches email, keep the lldap address
      tinker '$u = \FireflyIII\User::orderBy("id")->first(); $u->email = "${config.homelab.acmeEmail}"; $u->save();' >/dev/null
      [ -s "$out" ] && exit 0
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
    # 70: alpine postgres uid
    "d /var/lib/firefly/db 0750 70 70 -"
    "d /var/lib/firefly/upload 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
  homelab.ingressOnly.ports = [ 8080 ];
}
