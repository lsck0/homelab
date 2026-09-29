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
    # FinTS import: web ui that pulls Sparkasse transactions over FinTS into firefly.
    # bridge network (firefly holds host :8080), reaches firefly at the vm ip, which the
    # podman bridge (10.88.0.0/16) is a trusted source for past firefly's ingressOnly guard.
    firefly-fints-importer = {
      image = "docker.io/benkl/firefly-iii-fints-importer@sha256:9912f29e7c56587fbee2fceb146efe8f9f6ec924d5569f72aa7336b5c26e2a8e";
      # holds the saved config incl. the fints persistence string (bank access): local, 0700
      volumes = [ "/var/lib/firefly-fints:/app/configurations" ];
      ports = [ "8090:8080" ];
      environment.TZ = "Europe/Berlin";
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

  # seed the fints importer with firefly's url + token, so only the bank fields
  # are left to fill in the web ui; never clobbers a config the owner has saved.
  systemd.services.firefly-fints-seed = {
    description = "Pre-fill the FinTS importer config with Firefly URL and token";
    after = [ "firefly-hermes-token.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils pkgs.jq ];
    serviceConfig.Type = "oneshot";
    script = ''
      tok=/var/lib/homepage-tokens/firefly-token.token
      [ -s "$tok" ] || { echo "no firefly token yet"; exit 0; }
      out=/var/lib/firefly-fints/homelab.json
      [ -s "$out" ] && exit 0
      # bank_code/bank_url: Kreissparkasse Eichsfeld, from the hbci4java institute list
      jq -n --arg url "http://10.100.0.124:8080" --arg t "$(cat "$tok")" '{
        bank_username:"", bank_password:"",
        bank_code:"82057070", bank_url:"https://banking-th5.s-fints-pt-th.de/fints30",
        bank_2fa:"", bank_2fa_device:"", bank_fints_persistence:"",
        firefly_url:$url, firefly_access_token:$t, skip_transaction_review:"false",
        description_regex_match:"", description_regex_replace:"",
        auto_submit_form_via_js:false, force_mt940:false,
        choose_account_automation:{bank_account_iban:"", firefly_account_id:"", from:"now - 7 days", to:"now"}
      }' > "$out"
      chmod 600 "$out"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/firefly 0750 1000 1000 -"
    # 70: alpine postgres uid
    "d /var/lib/firefly/db 0750 70 70 -"
    "d /var/lib/firefly/upload 0750 1000 1000 -"
    # fints importer config + saved fints session, root-only (bank access)
    "d /var/lib/firefly-fints 0700 root root -"
  ];

  # 8090 is the fints importer ui; behind Traefik + Authelia like firefly, never raw on the LAN
  networking.firewall.allowedTCPPorts = [ 8080 8090 ];
  homelab.ingressOnly.ports = [ 8080 8090 ];
}
