# jellyfin, janitorr (deletes media nobody watches) and ollama (the lab's local llm), on the site's gpu if it has one
#
# Browsers log in only through authelia (jellyfin-plugin-sso), apps and jellyseerr by quick connect from a logged-in
# browser; password logins remain for the generated admin and janitorr. The lldap plugin is gone: it bound as lldap's
# admin and made the owner's sso password guessable, single factor, through /Users/AuthenticateByName. Its users keep
# their libraries and history (the sso plugin finds them by name); jellyfin refuses their old passwords.
#
# jellyfin-setup runs on every start: admin, api keys, libraries, janitorr's user, encoding, network, plugins, one
# restart if a step needs it, the sso plugin's settings. PartOf the container (a restart may bring a db a localState
# restore swapped), it restarts the server inside the container, never its own unit, so it cannot stop halfway.
{ config, lib, pkgs, inventory, catalog, nasMount, nasPath, setupUnit, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  # the site's passthrough gpu (instance.nix vm.pci maps it here); without one jellyfin and ollama use the cpu
  gpu = site.gpu != null;
  T = config.homelab.tokens.dir;
  ollama = import ../../modules/ollama.nix;

  route = catalog.internal.jellyfin;
  urlOf = name: let r = catalog.internal.${name}; in "http://${net.ipOf (toString r.vmid)}:${toString r.port}";
  publicUrl = "https://${net.fqdn route.host}";
  autheliaUrl = "https://${net.fqdn catalog.internal.authelia.host}";
  # the internal ingress, jellyfin's only trusted proxy: without it redirect_uri is http:// and authelia rejects it
  ingressIp = net.ipOf net.zones.internal.ingress;
  # the image listens here, the vm publishes it on the route's port
  containerPort = 8096;
  stateDir = "/var/lib/jellyfin";
  janitorrDir = "/var/lib/janitorr";
  mediaDir = "/data/media";
  leavingSoonDir = "${mediaDir}/leaving-soon";
  # janitorr's user and the owner of the state dirs
  uid = "1000";

  # one api key per consumer, so a leaked one is revoked alone: token jellyfin-key-<consumer>, jellyfin app
  # homelab-<consumer>. homepage (vm-103), hermes (vm-114), the *arr notifications (vm-130), janitorr (here)
  apiKeyConsumers = [ "homepage" "hermes" "arr" "janitorr" ];
  # the key every consumer shared before; revoked once the per-consumer keys exist
  apiKeyLegacyApp = "homelab";

  # a start runs the db migrations of a new version before the api answers; ten minutes bounds that, it is no wait
  readyTimeoutS = 600;
  # an in-process restart stops the server within seconds; longer means it ignored the request
  restartDownTimeoutS = 60;
  # the setup waits for ready at most twice (start, the one restart) and talks to the api in between
  setupTimeoutS = 2 * readyTimeoutS + 300;

  # the version installed live: a bump runs the plugin's own migrations, so it is a deliberate change here
  ssoVersion = "4.0.0.4";
  ssoPlugin = pkgs.fetchzip {
    url = "https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${ssoVersion}/sso-authentication_${ssoVersion}.zip";
    hash = "sha256-MJTyE6CeVLk7mlugauJ/F6bpi1kYwNtzNmQeH3+CFeQ=";
    stripRoot = false;
  };
  pluginsDir = "${stateDir}/config/plugins";
  ssoDir = "${pluginsDir}/SSO Authentication_${ssoVersion}";
  # login is for app-jellyfin members; admins among them get jellyfin's admin flag on top, never a way in alone
  ssoConfig = {
    SamlConfigs = { };
    OidConfigs.authelia = {
      OidEndpoint = autheliaUrl;
      OidClientId = "jellyfin";
      Enabled = true;
      EnableAuthorization = true;
      EnableAllFolders = true;
      EnabledFolders = [ ];
      AdminRoles = [ "admins" ];
      Roles = [ "app-jellyfin" ];
      EnableFolderRoles = false;
      RoleClaim = "groups";
      OidScopes = [ "groups" ];
      CanonicalLinks = { };
      DisableHttps = false;
      # authelia's client is not registered for par
      DisablePushedAuthorization = true;
      DoNotValidateEndpoints = false;
      DoNotValidateIssuerName = false;
    };
  };

  # janitorr: delete media unwatched this long
  unwatchedFor = "120d";
  janitorrPort = 8082;
  janitorrStatsPort = 8081;

  janitorrConfig = pkgs.writeText "janitorr.yml.tmpl" ''
    logging:
      level:
        com.github.schaka: INFO
    file-system:
      access: true
      validate-seeding: true
      leaving-soon-dir: "${leavingSoonDir}"
      media-server-leaving-soon-dir: "${leavingSoonDir}"
      from-scratch: true
      free-space-check-dir: "${mediaDir}"
    application:
      dry-run: false
      run-once: false
      whole-tv-show: false
      whole-show-seeding-check: false
      leaving-soon: 14d
      exclusion-tags:
        - "janitorr_keep"
      media-deletion:
        enabled: true
        movie-expiration:
          10: 30d
          25: 60d
          100: ${unwatchedFor}
        season-expiration:
          10: 30d
          25: 60d
          100: ${unwatchedFor}
      tag-based-deletion:
        enabled: false
      episode-deletion:
        enabled: false
    clients:
      sonarr:
        enabled: true
        url: "${urlOf "sonarr"}"
        api-key: "@SONARR@"
        delete-empty-shows: true
        determine-age-by: most_recent
      radarr:
        enabled: true
        url: "${urlOf "radarr"}"
        api-key: "@RADARR@"
        only-delete-files: false
        determine-age-by: most_recent
      bazarr:
        enabled: false
      jellyfin:
        enabled: true
        url: "${urlOf "jellyfin"}"
        api-key: "@JELLYFIN@"
        username: janitorr
        password: "@JANITORR_PASS@"
        delete: true
        exclude-favorited: true
        leaving-soon-tv: "Shows (Leaving Soon)"
        leaving-soon-movies: "Movies (Leaving Soon)"
        leaving-soon-type: MOVIES_AND_TV
      emby:
        enabled: false
      jellyseerr:
        enabled: true
        url: "${urlOf "jellyseerr"}"
        api-key: "@JELLYSEERR@"
        match-server: false
      jellystat:
        enabled: false
      streamystats:
        enabled: false
      janitorr-stats:
        enabled: true
        url: "http://127.0.0.1:${toString janitorrStatsPort}"
  '';

  statsConfig = pkgs.writeText "janitorr-stats.yml.tmpl" ''
    jellyfin:
      base-url: ${urlOf "jellyfin"}
      api-key: "@JELLYFIN@"
      poll-interval: 60s
    quarkus:
      http:
        port: ${toString janitorrStatsPort}
      datasource:
        db-kind: sqlite
        jdbc:
          url: jdbc:sqlite:/data/janitorr-stats.db
  '';

  # the setup's api toolkit. Credentials travel in files and on stdin, never on argv (/proc/*/cmdline is world
  # readable): the session token in a header file, the passwords through jq --rawfile
  jellyfinApi = ''
    J=http://127.0.0.1:${toString route.port}
    ADMIN_PASS_FILE=${T}/jellyfin-admin-pass.token
    AUTH_HEADER=$RUNTIME_DIRECTORY/auth.header
    # jellyfin 12 only accepts the Authorization header, the client fields identify the setup's session
    CLIENT_HEADER='Authorization: MediaBrowser Client="homelab", Device="setup", DeviceId="homelab-setup", Version="1.0"'
    POLL_S=2

    api() { curl -sSf -H @"$AUTH_HEADER" -H "Content-Type: application/json" "$@"; }

    # ready: the public info answers with the wizard state; a start answers 503 until its migrations finished
    jellyfin_wait_ready() {
      local deadline=$((SECONDS + ${toString readyTimeoutS})) info said="" last=""
      while :; do
        if info=$(curl -sSf --max-time 10 "$J/System/Info/Public" 2>&1) \
          && jq -e '.StartupWizardCompleted | type == "boolean"' <<<"$info" >/dev/null; then
          return 0
        fi
        # each new reason once, not a line every poll
        said=$(head -c 200 <<<"$info")
        [ "$said" = "$last" ] || echo "jellyfin not ready yet: $said"
        last=$said
        (( SECONDS < deadline )) || { echo "jellyfin not ready after ${toString readyTimeoutS}s" >&2; return 1; }
        sleep "$POLL_S"
      done
    }

    # the admin session; logins can fail for a moment after the api answers, a wrong password fails at once
    jellyfin_login() {
      local deadline=$((SECONDS + ${toString readyTimeoutS})) code body
      body=$(mktemp -p "$RUNTIME_DIRECTORY")
      while :; do
        code=$(jq -cn --rawfile p "$ADMIN_PASS_FILE" '{Username: "admin", Pw: $p}' \
          | curl -s -o "$body" -w '%{http_code}' -X POST "$J/Users/AuthenticateByName" \
              -H "Content-Type: application/json" -H "$CLIENT_HEADER" -d @-) || true
        case "$code" in
          200) jq -j '"Authorization: MediaBrowser Token=\"" + .AccessToken + "\"\n"' "$body" > "$AUTH_HEADER"
               rm -f "$body"; return 0 ;;
          401) echo "jellyfin rejects the admin password in $ADMIN_PASS_FILE" >&2; return 1 ;;
        esac
        (( SECONDS < deadline )) || { echo "jellyfin admin login failed (HTTP $code)" >&2; return 1; }
        sleep "$POLL_S"
      done
    }

    # in-process restart (POST /System/Restart): the container and its unit stay up, so nothing PartOf
    # podman-jellyfin restarts with it, this unit included
    jellyfin_restart() {
      api -X POST "$J/System/Restart"
      local deadline=$((SECONDS + ${toString restartDownTimeoutS}))
      # down first: the wait below is for the new start, not for the server still shutting down
      while curl -sf --max-time 2 "$J/System/Info/Public" >/dev/null 2>&1; do
        (( SECONDS < deadline )) || { echo "jellyfin ignored the restart request" >&2; return 1; }
        sleep 0.5
      done
      jellyfin_wait_ready
      jellyfin_login
    }

    # changes that apply only after a restart say so here; the setup restarts once, at the end
    RESTART_REASONS=""
    restart_needed() { RESTART_REASONS="''${RESTART_REASONS:+$RESTART_REASONS, }$1"; }

    plugin_find() { # <plugins json> <name regex> -> "<id> <version>" of that plugin, empty when it is not installed
      jq -r --arg n "$2" 'first(.[] | select(.Name | test($n; "i"))) | "\(.Id) \(.Version)"' <<<"$1"
    }
  '';
in {
  # janitorr cleans up through the arrs and jellyseerr
  homelab.tokens.reads = [ "radarr-key" "sonarr-key" "jellyseerr-key" ];

  # nvidia driver and cuda are unfree
  nixpkgs.config.allowUnfree = gpu;
  services.xserver.videoDrivers = lib.optional gpu "nvidia";
  boot.blacklistedKernelModules = lib.optional gpu "nouveau";
  hardware.graphics.enable = gpu;
  hardware.nvidia = lib.mkIf gpu {
    open = false;
    nvidiaSettings = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  hardware.nvidia-container-toolkit.enable = gpu;

  # local llm for paperless-ai
  services.ollama = {
    enable = true;
    host = "0.0.0.0";
    inherit (ollama) port;
    acceleration = if gpu then "cuda" else false;
    loadModels = [ ollama.model ];
    # drop models no longer listed
    syncModels = true;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "10m";
      OLLAMA_MAX_LOADED_MODELS = "1";
      OLLAMA_NUM_PARALLEL = "1";
    };
  };
  # 1.7 GiB peak measured, mostly the mmapped model
  systemd.services.ollama.serviceConfig.MemoryMax = "2560M";

  homelab.nasMounts = nasMount janitorrDir "janitorr" // nasPath "/data" "bulk";

  # jellyfin db local, the nas keeps a nightly copy
  homelab.localState.jellyfin = {
    path = stateDir;
    unit = "podman-jellyfin";
    sqlite = [ "config/data/*.db" ];
  };

  virtualisation.oci-containers.containers = {
    jellyfin = {
      image = "jellyfin/jellyfin:12.1";
      ports = [ "${toString route.port}:${toString containerPort}" ];
      volumes = [
        "${stateDir}/config:/config"
        "${stateDir}/cache:/cache"
        "${mediaDir}:${mediaDir}:ro"
      ];
      environment.JELLYFIN_PublishedServerUrl = publicUrl;
      # 425 MiB idle, transcodes run in the same cgroup
      extraOptions = lib.optional gpu "--device=nvidia.com/gpu=all" ++ [ "--memory=1g" ];
    };

    janitorr-stats = {
      image = "ghcr.io/schaka/janitorr-stats:v0.2.6-sqlite";
      volumes = [
        "${janitorrDir}/stats.yml:/work/config/application.yml:ro"
        "${janitorrDir}/stats:/data"
      ];
      # 131 MiB measured
      extraOptions = [ "--network=host" "--memory=256m" ];
    };

    janitorr = {
      image = "ghcr.io/schaka/janitorr:jvm-v2.2.1";
      user = "${uid}:${uid}";
      dependsOn = [ "janitorr-stats" ];
      volumes = [
        "${janitorrDir}/application.yml:/config/application.yml:ro"
        "${janitorrDir}/logs:/logs"
        "${mediaDir}:${mediaDir}"
        "/data/torrents:/data/torrents"
      ];
      # host network, beside jellyfin's port and janitorr-stats'
      environment.SERVER_PORT = toString janitorrPort;
      extraOptions = [ "--network=host" "--memory=512m" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir}/config 0750 ${uid} ${uid} -"
    "d ${stateDir}/cache 0750 ${uid} ${uid} -"
    "d ${janitorrDir}/logs 0750 ${uid} ${uid} -"
    "d ${janitorrDir}/stats 0750 ${uid} ${uid} -"
  ];

  systemd.services.jellyfin-setup = setupUnit {
    description = "Set up Jellyfin (admin, API keys, libraries, janitorr, network, Authelia SSO)";
    partOf = [ "podman-jellyfin.service" ];
    after = [ "podman-jellyfin.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.diffutils pkgs.findutils ];
    serviceConfig = {
      RuntimeDirectory = "jellyfin-setup";
      RuntimeDirectoryMode = "0700";
      TimeoutStartSec = setupTimeoutS;
    };
    script = ''
      ${jellyfinApi}
      token_secret_ensure jellyfin-admin-pass
      jellyfin_wait_ready

      # -- admin: the first start runs the wizard with the generated password
      if curl -sSf "$J/System/Info/Public" | jq -e '.StartupWizardCompleted == false' >/dev/null; then
        curl -sSf -X POST "$J/Startup/Configuration" -H "Content-Type: application/json" \
          -d '{"UICulture":"en-US","MetadataCountryCode":"DE","PreferredMetadataLanguage":"en"}'
        # the wizard needs its default user loaded first
        curl -sSf "$J/Startup/User" >/dev/null
        jq -cn --rawfile p "$ADMIN_PASS_FILE" '{Name: "admin", Password: $p}' \
          | curl -sSf -X POST "$J/Startup/User" -H "Content-Type: application/json" -d @-
        curl -sSf -X POST "$J/Startup/Complete"
        echo "wizard done, admin created"
      fi
      jellyfin_login

      # -- api keys, one per consumer; then the shared one goes
      keys_of() { # <app name> -> its keys, one per line
        jq -r --arg a "$1" '.Items[] | select(.AppName == $a) | .AccessToken' <<<"$keys"
      }
      keys=$(api "$J/Auth/Keys")
      for consumer in ${lib.escapeShellArgs apiKeyConsumers}; do
        key=$(keys_of "homelab-$consumer")
        if [ -z "$key" ]; then
          api -X POST "$J/Auth/Keys?app=homelab-$consumer"
          keys=$(api "$J/Auth/Keys")
          key=$(keys_of "homelab-$consumer")
        fi
        # a second key of the same app would be a hand-made one; the first stays the consumer's
        printf '%s' "''${key%%$'\n'*}" | token_write "jellyfin-key-$consumer"
      done
      for legacy in $(keys_of ${apiKeyLegacyApp}); do
        api -X DELETE "$J/Auth/Keys/$legacy"
        echo "revoked the shared api key ${apiKeyLegacyApp}"
      done
      rm -f ${config.homelab.tokens.ownDir}/jellyfin-key.token

      # -- libraries; nfs has no inotify, arr imports trigger scans
      have=$(api "$J/Library/VirtualFolders" | jq -r '.[].Name')
      library_ensure() { # <name> <collection type> <path>
        grep -qx "$1" <<<"$have" && return 0
        api -X POST "$J/Library/VirtualFolders?name=$1&collectionType=$2&paths=$3&refreshLibrary=true" \
          -d '{"LibraryOptions":{"EnableRealtimeMonitor":true}}'
        echo "library $1 created"
      }
      library_ensure Movies movies ${mediaDir}/movies
      library_ensure Shows tvshows ${mediaDir}/tv
      library_ensure Anime tvshows ${mediaDir}/anime

      # new libraries have no metadata fetchers
      fetchers() { # <jq array of type names> -> TypeOptions for those types
        jq -cn --argjson types "$1" '[$types[] | {
          Type: .,
          MetadataFetchers: ["TheMovieDb"], MetadataFetcherOrder: ["TheMovieDb"],
          ImageFetchers: ["TheMovieDb"],    ImageFetcherOrder: ["TheMovieDb"],
          ImageOptions: []
        }]'
      }
      api "$J/Library/VirtualFolders" | jq -c '.[]' | while read -r folder; do
        [ "$(jq -r '.LibraryOptions.EnableInternetProviders' <<<"$folder")" = true ] && continue
        case "$(jq -r .CollectionType <<<"$folder")" in
          movies)  types='["Movie"]' ;;
          tvshows) types='["Series","Season","Episode"]' ;;
          *) continue ;;
        esac
        jq -c --argjson t "$(fetchers "$types")" \
          '{Id: .ItemId, LibraryOptions: (.LibraryOptions | .EnableInternetProviders = true | .TypeOptions = $t)}' \
          <<<"$folder" | api -X POST "$J/Library/VirtualFolders/LibraryOptions" -d @-
        echo "library $(jq -r .Name <<<"$folder"): metadata fetching enabled"
      done

      # -- janitorr deletes through a user of its own: content deletion, no admin
      token_secret_ensure janitorr-pass
      janitorr_id=$(api "$J/Users" | jq -r 'first(.[] | select(.Name == "janitorr")) | .Id')
      if [ -z "$janitorr_id" ]; then
        janitorr_id=$(jq -cn --rawfile p ${T}/janitorr-pass.token '{Name: "janitorr", Password: $p}' \
          | api -X POST "$J/Users/New" -d @- | jq -er .Id)
        echo "user janitorr created"
      fi
      policy=$(api "$J/Users/$janitorr_id" | jq -c .Policy)
      want=$(jq -c '.IsAdministrator = false | .EnableContentDeletion = true | .IsHidden = true' <<<"$policy")
      [ "$policy" = "$want" ] || { api -X POST "$J/Users/$janitorr_id/Policy" -d "$want"; echo "janitorr policy set"; }

      # -- encoding; turing: no av1 decode
      enc=$(api "$J/System/Configuration/encoding" | jq -c .)
      want=$(jq -c '
        .HardwareAccelerationType = "${if gpu then "nvenc" else "none"}"
        | .EnableHardwareEncoding = true
        | .HardwareDecodingCodecs = ["h264","hevc","mpeg2video","vc1","vp8","vp9"]
        | .EnableDecodingColorDepth10Hevc = true
        | .EnableDecodingColorDepth10Vp9 = true
        | .EnableTonemapping = true
        | .AllowHevcEncoding = true' <<<"$enc")
      [ "$enc" = "$want" ] || { api -X POST "$J/System/Configuration/encoding" -d "$want"; echo "encoding set"; }

      # -- quick connect: apps and jellyseerr log in by pairing with a browser session, the way in besides authelia
      sys=$(api "$J/System/Configuration" | jq -c .)
      want=$(jq -c '.QuickConnectAvailable = true' <<<"$sys")
      [ "$sys" = "$want" ] || { api -X POST "$J/System/Configuration" -d "$want"; echo "quick connect enabled"; }

      # -- network: the ingress is the trusted proxy, links point at the public name
      net=$(api "$J/System/Configuration/network" | jq -c .)
      want=$(jq -c --arg proxy ${ingressIp} --arg url ${publicUrl} \
        '.KnownProxies = [$proxy] | .PublishedServerUriBySubnet = ["all=" + $url]' <<<"$net")
      if [ "$net" != "$want" ]; then
        api -X POST "$J/System/Configuration/network" -d "$want"
        restart_needed "network settings"
      fi

      # -- the lldap plugin is retired: its stored bind password is blanked first, an uninstall may leave the file
      plugins=$(api "$J/Plugins")
      read -r ldap_id ldap_version <<<"$(plugin_find "$plugins" '^LDAP')"
      if [ -n "$ldap_id" ]; then
        api "$J/Plugins/$ldap_id/Configuration" | jq -c '.LdapBindUser = "" | .LdapBindPassword = ""' \
          | api -X POST "$J/Plugins/$ldap_id/Configuration" -d @-
        api -X DELETE "$J/Plugins/$ldap_id/$ldap_version"
        restart_needed "ldap plugin removed"
      fi

      # -- plugins come from the store alone: no repository, so nothing installs or updates behind this unit
      if ! api "$J/Repositories" | jq -e 'length == 0' >/dev/null; then
        api -X POST "$J/Repositories" -d '[]'
        echo "plugin repositories removed"
      fi
      # authelia sso, the pinned build; jellyfin rewrites meta.json, so only the assemblies are compared
      for dll in ${ssoPlugin}/*.dll; do
        cmp -s "$dll" "${ssoDir}/''${dll##*/}" && continue
        find ${pluginsDir} -maxdepth 1 -name 'SSO Authentication_*' -exec rm -rf {} +
        install -D -m 0644 -t "${ssoDir}" ${ssoPlugin}/*
        restart_needed "sso plugin ${ssoVersion} installed"
        break
      done

      # -- the one restart
      if [ -n "$RESTART_REASONS" ]; then
        echo "restarting jellyfin once: $RESTART_REASONS"
        jellyfin_restart
      fi

      plugins=$(api "$J/Plugins")
      read -r sso_id _ <<<"$(plugin_find "$plugins" '^SSO')"
      [ -n "$sso_id" ] || { echo "the sso plugin is not loaded after the restart" >&2; exit 1; }
      jq -c --rawfile secret ${config.sops.secrets.jellyfin-oidc-secret.path} \
        '.OidConfigs.authelia.OidSecret = ($secret | rtrimstr("\n"))' ${pkgs.writeText "jellyfin-sso.json" (builtins.toJSON ssoConfig)} \
        | api -X POST "$J/Plugins/$sso_id/Configuration" -d @-
      rm -f "$AUTH_HEADER"
      echo "jellyfin set up, browser logins go through authelia"
    '';
  };

  sops.secrets.jellyfin-oidc-secret = {};

  # render janitorr's configs from the exported api keys
  systemd.services.janitorr-config = setupUnit {
    description = "Render Janitorr configuration from exported API keys";
    after = [ "jellyfin-setup.service" ];
    wants = [ "jellyfin-setup.service" ];
    before = [ "podman-janitorr.service" "podman-janitorr-stats.service" ];
    wantedBy = [ "podman-janitorr.service" "podman-janitorr-stats.service" ];
    path = [ pkgs.coreutils ];
    script = ''
      # token_read checks each value is a token, so none carries a yaml quote or a second line
      radarr=$(token_read radarr-key) && sonarr=$(token_read sonarr-key) && jellyseerr=$(token_read jellyseerr-key) \
        && jellyfin=$(token_read jellyfin-key-janitorr) && janitorr=$(token_read janitorr-pass) \
        || { echo "waiting for the arr, jellyseerr and jellyfin keys"; exit 1; }
      render() { # <template> <target>; substituted in the shell, so no key passes through argv
        local text
        text=$(cat "$1")
        text=''${text//@RADARR@/$radarr}; text=''${text//@SONARR@/$sonarr}; text=''${text//@JELLYFIN@/$jellyfin}
        text=''${text//@JELLYSEERR@/$jellyseerr}; text=''${text//@JANITORR_PASS@/$janitorr}
        (umask 077; printf '%s\n' "$text" > "$2.tmp")
        chown ${uid}:${uid} "$2.tmp"; mv "$2.tmp" "$2"
      }
      render ${janitorrConfig} ${janitorrDir}/application.yml
      render ${statsConfig} ${janitorrDir}/stats.yml
    '';
  };

  # ollama is no route: its port and guard are here, its client a grant in instance.nix
  networking.firewall.allowedTCPPorts = [ ollama.port ];
  homelab.ingressOnly.ports = [ ollama.port ];

  # vfio pins all ram, so dropped caches return nothing to the host
  homelab.dropCaches = false;
}
