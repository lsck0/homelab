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

  # api token for hermes (and the fints importer). the firefly image dropped `tinker`,
  # so bootstrap the framework directly and mint a passport personal access token.
  systemd.services.firefly-hermes-token = {
    description = "Export a Firefly III API token for Hermes";
    after = [ "podman-firefly.service" ];
    path = [ pkgs.podman pkgs.coreutils pkgs.gnused ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=/var/lib/homepage-tokens/firefly-token.token
      [ -s "$out" ] && exit 0

      # runs inside the firefly container: sets the owner's email to match the
      # lldap/authelia address, then prints a fresh token between markers. firefly
      # logs warnings to stdout, so the markers let us extract just the jwt.
      script=$(mktemp)
      cat > "$script" <<'PHP'
      <?php
      require "/var/www/html/vendor/autoload.php";
      $app = require "/var/www/html/bootstrap/app.php";
      $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
      $u = \FireflyIII\User::orderBy("id")->first();
      if (!$u) { fwrite(STDERR, "no user\n"); exit(1); }
      $u->email = getenv("FF_EMAIL"); $u->save();
      echo "\n<<TOKEN>>".$u->createToken("homelab")->accessToken."<<END>>\n";
      PHP
      podman cp "$script" firefly:/tmp/mktoken.php
      rm -f "$script"
      # the personal access client must exist once; harmless if it already does
      podman exec firefly php artisan passport:client --personal --no-interaction >/dev/null 2>&1 || true

      raw=$(podman exec -e FF_EMAIL=${config.homelab.acmeEmail} firefly php /tmp/mktoken.php 2>&1) || true
      podman exec firefly rm -f /tmp/mktoken.php
      token=$(printf '%s' "$raw" | sed -n 's/.*<<TOKEN>>\(ey[^<]*\)<<END>>.*/\1/p')
      [ "''${token:0:2}" = ey ] || { echo "no Firefly user yet, or token creation failed"; exit 0; }
      printf '%s' "$token" > "$out"
    '';
  };
  systemd.timers.firefly-hermes-token = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "30m"; };
  };

  # seed the fints importer config so the web ui only needs username + PIN + TAN.
  # runs at boot and after every token refresh; rewrites until the owner saves a
  # config with real bank credentials, then leaves it alone (persistence string).
  systemd.services.firefly-fints-seed = {
    description = "Pre-fill the FinTS importer config (bank + Firefly)";
    after = [ "firefly-hermes-token.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.coreutils pkgs.jq ];
    serviceConfig.Type = "oneshot";
    script = ''
      out=/var/lib/firefly-fints/homelab.json
      # once the owner has saved bank credentials in the ui, never touch it again
      if [ -s "$out" ] && [ -n "$(jq -r '.bank_username // ""' "$out")" ]; then exit 0; fi
      # firefly token is filled once it exists; the bank fields do not depend on it
      tok=/var/lib/homepage-tokens/firefly-token.token
      t=""; [ -s "$tok" ] && t="$(cat "$tok")"
      # bank_code/bank_url: Kreissparkasse Eichsfeld (hbci4java institute list); 2fa 923 = pushTAN 2.0
      jq -n --arg url "http://10.100.0.124:8080" --arg t "$t" '{
        bank_username:"", bank_password:"",
        bank_code:"82057070", bank_url:"https://banking-th5.s-fints-pt-th.de/fints30",
        # 911 = chipTAN manuell (insert card, type the startcode, read the tan); bank rejects
        # pushTAN 923 over fints; 913 QR / 912 flicker need those generator types instead
        bank_2fa:"911", bank_2fa_device:"", bank_fints_persistence:"",
        firefly_url:$url, firefly_access_token:$t, skip_transaction_review:"false",
        description_regex_match:"", description_regex_replace:"",
        auto_submit_form_via_js:false, force_mt940:false,
        choose_account_automation:{bank_account_iban:"", firefly_account_id:"", from:"now - 7 days", to:"now"}
      }' > "$out"
      chmod 600 "$out"
    '';
  };
  # refill (esp. the firefly token) shortly after boot and periodically, like the token export
  systemd.timers.firefly-fints-seed = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "6m"; OnUnitActiveSec = "30m"; };
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
