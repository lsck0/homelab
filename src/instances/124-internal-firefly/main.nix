# firefly iii with its own postgres, and the fints importer that pulls the bank's transactions into it
#
# firefly's :8080 logs in whoever the Remote-Email header names, and the importer is a third-party container that
# renders bank pages. So the importer runs on a podman network of its own (outside the default bridge every guard
# trusts) and reaches firefly only through the api proxy, which drops the identity headers: all it can use is its
# api token. The bank's fields of the importer config (code, url, tan method, account, the persistence string) are
# entered once in the importer ui and stay in a local file, never the public repo; firefly-fints-seed keeps only
# firefly's address and token current. The daily headless import reuses the stored persistence to skip the tan;
# once bank credentials exist, anything but a clean import fails the unit, so the failed-unit alert says the bank
# wants a new tan or the importer broke.
{ config, lib, pkgs, inventory, catalog, lab, nasMount, retry, setupUnit, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  route = catalog.internal.firefly;
  fintsRoute = catalog.internal.fints;
  local = "http://127.0.0.1:${toString route.port}";
  url = "https://${net.fqdn route.host}";
  dataDir = "/var/lib/firefly";
  db = "firefly";
  # the bank import runs at the vm's daily wake
  importAt = lab.instances."124".config.idle.wakeAt;
  uiPorts = [ route.port fintsRoute.port ];
  fintsImage = "docker.io/benkl/firefly-iii-fints-importer@sha256:9912f29e7c56587fbee2fceb146efe8f9f6ec924d5569f72aa7336b5c26e2a8e";
  fintsDir = "/var/lib/firefly-fints";
  fintsConfig = "${fintsDir}/homelab.json";
  # host network: php-fpm would listen on every address; a later [www] section overrides the image's pool
  fpmLoopback = pkgs.writeText "zzzz-listen.conf" ''
    [www]
    listen = 127.0.0.1:9000
  '';

  fintsNetwork = { name = "fints"; interface = "fints0"; subnet = "10.89.124.0/24"; gateway = "10.89.124.1"; };
  fireflyApiProxyPort = 8081;
  fireflyApiProxyUrl = "http://${fintsNetwork.gateway}:${toString fireflyApiProxyPort}";
  # the image's own port, published for the ingress on the route's
  fintsContainerPort = 8080;

  # bootstraps firefly's framework inside its container (the image dropped `tinker`); the code is the argument
  fireflyPhp = code: pkgs.writeText "firefly-boot.php" ''
    <?php
    require "/var/www/html/vendor/autoload.php";
    $app = require "/var/www/html/bootstrap/app.php";
    $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
    ${code}
  '';
  # firefly logs warnings to stdout: the token comes between markers
  mintToken = fireflyPhp ''
    $u = \FireflyIII\User::orderBy("id")->first();
    if (!$u) { echo "\n<<NOUSER>>\n"; exit(0); }
    echo "\n<<TOKEN>>".$u->createToken("homelab")->accessToken."<<END>>\n";
  '';
  # authelia sends the owner's lldap mail as Remote-Email; firefly's first account must carry it
  ownerEmail = fireflyPhp ''
    $u = \FireflyIII\User::orderBy("id")->first();
    if (!$u) { echo "no user yet\n"; exit(0); }
    if ($u->email !== getenv("FF_EMAIL")) { $u->email = getenv("FF_EMAIL"); $u->save(); echo "owner email set\n"; }
  '';
  # firefly_run <php file> [podman exec args]: copy it in, run it, remove it; then wait for firefly to answer
  fireflyReady = ''
    firefly_run() {
      local file=$1; shift
      podman cp "$file" firefly:/tmp/homelab.php
      podman exec "$@" firefly php /tmp/homelab.php
      podman exec firefly rm -f /tmp/homelab.php
    }

    ${retry} 60 5 curl -sf ${local}/health'';
in {
  networking.hostName = "vm-124";

  homelab.nasMounts = nasMount dataDir "firefly";

  sops.secrets.firefly-app-key = {};
  sops.secrets.firefly-db-password = {};
  sops.templates."firefly.env".restartUnits = [ "podman-firefly.service" ];
  sops.templates."firefly.env".content = ''
    APP_KEY=${config.sops.placeholder.firefly-app-key}
    DB_CONNECTION=pgsql
    DB_HOST=127.0.0.1
    DB_PORT=5432
    DB_DATABASE=${db}
    DB_USERNAME=${db}
    DB_PASSWORD=${config.sops.placeholder.firefly-db-password}
    APP_URL=${url}
    # the internal ingress and the importer's proxy (loopback) are the only proxies; their x-forwarded-* count
    TRUSTED_PROXIES=${net.ipOf net.zones.internal.ingress},127.0.0.1
    # login via authelia's Remote-Email
    AUTHENTICATION_GUARD=remote_user_guard
    AUTHENTICATION_GUARD_HEADER=HTTP_REMOTE_EMAIL
    AUTHENTICATION_GUARD_EMAIL=HTTP_REMOTE_EMAIL
  '';
  sops.templates."firefly-db.env".content = ''
    POSTGRES_DB=${db}
    POSTGRES_USER=${db}
    POSTGRES_PASSWORD=${config.sops.placeholder.firefly-db-password}
  '';

  virtualisation.oci-containers.containers = {
    firefly-db = {
      image = "docker.io/library/postgres:16.15-alpine";
      # host network: only firefly beside it connects
      cmd = [ "postgres" "-c" "listen_addresses=127.0.0.1" ];
      volumes = [ "${dataDir}/db:/var/lib/postgresql/data" ];
      environmentFiles = [ config.sops.templates."firefly-db.env".path ];
      extraOptions = [ "--network=host" ];
    };
    firefly = {
      image = "docker.io/fireflyiii/core:version-6.7.2";
      dependsOn = [ "firefly-db" ];
      # host network: the route's port, postgres on 127.0.0.1:5432
      volumes = [
        "${dataDir}/upload:/var/www/html/storage/upload"
        "${fpmLoopback}:/usr/local/etc/php-fpm.d/zzzz-listen.conf:ro"
      ];
      environmentFiles = [ config.sops.templates."firefly.env".path ];
      extraOptions = [ "--network=host" ];
    };
    firefly-fints-importer = {
      image = fintsImage;
      networks = [ fintsNetwork.name ];
      # holds the saved config incl. the fints persistence string (bank access): local, 0700
      volumes = [
        "${fintsDir}:/app/configurations"
        # from firefly-fints-patch
        "${fintsDir}/TanHandler.php:/app/TanHandler.php:ro"
        "${fintsDir}/RunImportBatched.php:/app/RunImportBatched.php:ro"
      ];
      ports = [ "${toString fintsRoute.port}:${toString fintsContainerPort}" ];
      environment.TZ = site.timeZone;
    };
  };

  systemd.services.podman-network-fints = {
    description = "Podman network for the FinTS importer";
    requiredBy = [ "podman-firefly-fints-importer.service" ];
    before = [ "podman-firefly-fints-importer.service" ];
    path = [ config.virtualisation.podman.package ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      podman network exists ${fintsNetwork.name} || podman network create --interface-name=${fintsNetwork.interface} \
        --subnet=${fintsNetwork.subnet} --gateway=${fintsNetwork.gateway} ${fintsNetwork.name}
    '';
  };

  # every address: the bridge appears only with the container; the firewall opens it on the importer's bridge alone
  services.nginx = {
    enable = true;
    virtualHosts.firefly-api = {
      listen = [ { addr = "0.0.0.0"; port = fireflyApiProxyPort; } ];
      extraConfig = ''
        allow ${fintsNetwork.subnet};
        deny all;
      '';
      locations."/" = {
        proxyPass = local;
        extraConfig = ''
          proxy_set_header Remote-User "";
          proxy_set_header Remote-Email "";
          proxy_set_header Remote-Groups "";
          proxy_set_header Remote-Name "";
        '';
      };
    };
  };
  networking.firewall.interfaces.${fintsNetwork.interface}.allowedTCPPorts = [ fireflyApiProxyPort ];

  # the patched php comes from the pinned image on every start, so an image bump re-derives it (lib/firefly-fints-patch.py)
  systemd.services.firefly-fints-patch = {
    description = "Patch the FinTS importer (chipTAN challenge + persistence dump)";
    before = [ "podman-firefly-fints-importer.service" ];
    requiredBy = [ "podman-firefly-fints-importer.service" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.podman pkgs.python3 pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      d=${fintsDir}; mkdir -p "$d"
      podman image exists ${fintsImage} || podman pull ${fintsImage}
      cid=$(podman create ${fintsImage})
      podman cp "$cid:/app/TanHandler.php" "$d/TanHandler.php.orig"
      podman cp "$cid:/app/RunImportBatched.php" "$d/RunImportBatched.php.orig"
      podman rm "$cid" >/dev/null
      python3 ${./lib/firefly-fints-patch.py} "$d"
      rm -f "$d"/*.orig
    '';
  };

  # dump, the nas holds a live data dir
  homelab.dbBackup.databases.firefly = {
    command = "podman exec firefly-db pg_dump -U ${db} --clean --if-exists ${db}";
    path = [ pkgs.podman ];
  };

  systemd.services.firefly-owner-email = setupUnit {
    description = "Give Firefly III's owner account the owner's mail";
    after = [ "podman-firefly.service" ];
    path = [ pkgs.podman pkgs.curl ];
    script = ''
      ${fireflyReady}
      firefly_run ${ownerEmail} -e FF_EMAIL=${config.homelab.acmeEmail}
    '';
  };

  # rechecked every half hour: the owner may register later and a db restore revokes the token
  systemd.services.firefly-hermes-token = setupUnit {
    description = "Export a Firefly III API token for Hermes and the FinTS importer";
    after = [ "podman-firefly.service" "firefly-owner-email.service" ];
    # the timer runs it; a failed check waits for the next tick
    wantedBy = [ ];
    serviceConfig = { RemainAfterExit = false; Restart = "no"; };
    path = [ pkgs.podman pkgs.coreutils pkgs.curl pkgs.gnused ];
    script = ''
      ${fireflyReady}
      if current=$(token_read firefly-token); then
        status=$(printf 'Authorization: Bearer %s\n' "$current" \
          | curl -s -o /dev/null -w '%{http_code}' -H @- -H 'Accept: application/json' ${local}/api/v1/about/user)
        case "$status" in
          200) echo "firefly token valid"; exit 0 ;;
          401) echo "firefly token rejected, minting a new one" ;;
          *) echo "firefly token check inconclusive (HTTP $status)" >&2; exit 1 ;;
        esac
      fi
      # the personal access client must exist once; the command only creates it
      if ! podman exec firefly php artisan passport:client --personal --no-interaction >/dev/null; then
        echo "passport:client failed" >&2; exit 1
      fi
      raw=$(firefly_run ${mintToken})
      if grep -q '<<NOUSER>>' <<<"$raw"; then
        echo "no Firefly account yet: the owner registers at ${url} first"
        exit 0
      fi
      sed -n 's/.*<<TOKEN>>\(ey[^<]*\)<<END>>.*/\1/p' <<<"$raw" | token_write firefly-token
    '';
  };
  systemd.timers.firefly-hermes-token = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "30m"; };
  };

  systemd.services.firefly-fints-seed = setupUnit {
    description = "Point the FinTS importer config at Firefly III";
    wants = [ "firefly-hermes-token.service" ];
    after = [ "firefly-hermes-token.service" ];
    path = [ pkgs.coreutils pkgs.jq ];
    script = ''
      token=$(token_read firefly-token 2>/dev/null || true)
      current='{}'
      [ -s ${fintsConfig} ] && current=$(cat ${fintsConfig})
      jq --arg url ${fireflyApiProxyUrl} --arg t "$token" '{
        bank_username: "", bank_password: "", bank_code: "", bank_url: "",
        bank_2fa: "", bank_2fa_device: "", bank_fints_persistence: "",
        skip_transaction_review: "false", description_regex_match: "", description_regex_replace: "",
        auto_submit_form_via_js: false, force_mt940: false,
        choose_account_automation: { bank_account_iban: "", firefly_account_id: "", from: "now - 2 years", to: "now" }
      } * . + { firefly_url: $url, firefly_access_token: $t }' <<<"$current" > ${fintsConfig}.tmp
      chmod 600 ${fintsConfig}.tmp
      mv ${fintsConfig}.tmp ${fintsConfig}
    '';
  };
  # refill the firefly token once it exists
  systemd.timers.firefly-fints-seed = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "6m"; OnUnitActiveSec = "30m"; };
  };

  systemd.services.firefly-fints-import = {
    description = "Headless FinTS import into Firefly III";
    after = [ "podman-firefly-fints-importer.service" ];
    path = [ pkgs.curl pkgs.gnugrep pkgs.jq pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RuntimeDirectory = "firefly-fints-import"; };
    script = ''
      set -euo pipefail
      if [ -z "$(jq -r '.bank_username // ""' ${fintsConfig})" ]; then
        echo "no bank credentials yet, skipping"; exit 0
      fi
      out=$RUNTIME_DIRECTORY/response.html
      code=$(curl -s -o "$out" -w '%{http_code}' "http://127.0.0.1:${toString fintsRoute.port}/?automate=true&config=homelab.json")
      clean="imported [0-9]+|no transactions"
      broken="error|exception|fatal"
      summary=$(grep -ioE "$clean|$broken|tan" "$out" | sort | uniq -c | tr '\n' ' ' || true)
      echo "import: http $code, $summary"
      [ "$code" = 200 ] || { echo "the importer answered HTTP $code" >&2; exit 1; }
      if grep -qiE "$broken" "$out"; then echo "the import failed, see the summary above" >&2; exit 1; fi
      # the stored persistence expired: the bank wants a tan, which only the ui can take
      if grep -qiw "tan" "$out" && ! grep -qiE "$clean" "$out"; then
        echo "the bank asks for a TAN: run the import once in the importer ui" >&2; exit 1
      fi
    '';
  };
  systemd.timers.firefly-fints-import = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = importAt; Persistent = true; RandomizedDelaySec = "20m"; };
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 1000 1000 -"
    # 70: alpine postgres uid
    "d ${dataDir}/db 0750 70 70 -"
    "d ${dataDir}/upload 0750 1000 1000 -"
    # fints importer config + saved fints session, root-only (bank access)
    "d ${fintsDir} 0700 root root -"
  ];

  # the importer ui is behind traefik and authelia like firefly, never raw on the lan
  networking.firewall.allowedTCPPorts = uiPorts;
  homelab.ingressOnly = {
    ports = uiPorts;
    # no container here uses the default bridge, and the importer must never pass the Remote-Email guard
    trustContainers = false;
  };
}
