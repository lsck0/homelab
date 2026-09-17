{ pkgs, nasMount, nasPath, ... }:
let
  T = "/var/lib/homepage-tokens";

  # Janitorr: media not watched (janitorr-stats play history) or, if never
  # watched, not grabbed for this long is deleted via Radarr/Sonarr/Jellyfin.
  # shorter when the disk fills up. It shows in a "Leaving Soon" collection
  # 14 days before. Tag media `janitorr_keep` in Radarr/Sonarr to keep it.
  unwatchedFor = "120d";

  janitorrConfig = pkgs.writeText "janitorr.yml.tmpl" ''
    logging:
      level:
        com.github.schaka: INFO
    file-system:
      access: true
      validate-seeding: true
      leaving-soon-dir: "/data/media/leaving-soon"
      media-server-leaving-soon-dir: "/data/media/leaving-soon"
      from-scratch: true
      free-space-check-dir: "/data/media"
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
        url: "http://10.100.0.130"
        api-key: "@SONARR@"
        delete-empty-shows: true
        determine-age-by: most_recent
      radarr:
        enabled: true
        url: "http://10.100.0.129"
        api-key: "@RADARR@"
        only-delete-files: false
        determine-age-by: most_recent
      bazarr:
        enabled: false
      jellyfin:
        enabled: true
        url: "http://10.100.0.133"
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
        url: "http://10.100.0.127"
        api-key: "@JELLYSEERR@"
        match-server: false
      jellystat:
        enabled: false
      streamystats:
        enabled: false
      janitorr-stats:
        enabled: true
        url: "http://127.0.0.1:8081"
  '';

  statsConfig = pkgs.writeText "janitorr-stats.yml.tmpl" ''
    jellyfin:
      base-url: http://10.100.0.133
      api-key: "@JELLYFIN@"
      poll-interval: 60s
    quarkus:
      http:
        port: 8081
      datasource:
        db-kind: sqlite
        jdbc:
          url: jdbc:sqlite:/data/janitorr-stats.db
  '';
in {
  networking.hostName = "vm-133";

  # /data/media rw on the VM (Janitorr writes the leaving-soon links),
  # read-only inside the Jellyfin container.
  fileSystems = nasMount "/var/lib/jellyfin" "jellyfin"
    // nasMount "/var/lib/janitorr" "janitorr"
    // nasPath "/data/media" "media"
    // nasPath "/data/torrents" "torrents"
    // nasMount T "homepage-tokens";

  virtualisation.oci-containers.containers = {
    jellyfin = {
      image = "jellyfin/jellyfin:latest";
      ports = [ "80:8096" ];
      volumes = [
        "/var/lib/jellyfin/config:/config"
        "/var/lib/jellyfin/cache:/cache"
        "/data/media:/data/media:ro"
      ];
      environment.JELLYFIN_PublishedServerUrl = "https://jellyfin.lsck0.dev";
    };

    janitorr-stats = {
      image = "ghcr.io/schaka/janitorr-stats:stable-sqlite";
      volumes = [
        "/var/lib/janitorr/stats.yml:/work/config/application.yml:ro"
        "/var/lib/janitorr/stats:/data"
      ];
      extraOptions = [ "--network=host" ];
    };

    janitorr = {
      image = "ghcr.io/schaka/janitorr:jvm-stable";
      user = "1000:1000";
      dependsOn = [ "janitorr-stats" ];
      volumes = [
        "/var/lib/janitorr/application.yml:/config/application.yml:ro"
        "/var/lib/janitorr/logs:/logs"
        "/data/media:/data/media"
        "/data/torrents:/data/torrents"
      ];
      # host network: its web port must not collide with Jellyfin's 8096/80.
      environment.SERVER_PORT = "8082";
      extraOptions = [ "--network=host" "--memory=512m" ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/jellyfin/config 0750 1000 1000 -"
    "d /var/lib/jellyfin/cache 0750 1000 1000 -"
    "d /var/lib/janitorr/logs 0750 1000 1000 -"
    "d /var/lib/janitorr/stats 0750 1000 1000 -"
  ];

  # first run: admin user, libraries, API key for Homepage/Janitorr/Hermes,
  # and a deletion-capable `janitorr` user. Idempotent.
  systemd.services.jellyfin-setup = {
    description = "Initialise Jellyfin (admin, libraries, API key, janitorr user)";
    after = [ "podman-jellyfin.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 60; };
    script = ''
      J=http://127.0.0.1:80
      for i in $(seq 1 90); do curl -sf $J/health >/dev/null && break; sleep 2; done

      [ -s ${T}/jellyfin-admin-pass.token ] || openssl rand -hex 16 | tr -d '\n' > ${T}/jellyfin-admin-pass.token
      ADMIN_PASS=$(cat ${T}/jellyfin-admin-pass.token)

      if curl -sf $J/System/Info/Public | jq -e '.StartupWizardCompleted == false' >/dev/null; then
        curl -sf -X POST $J/Startup/Configuration -H "Content-Type: application/json" \
          -d '{"UICulture":"en-US","MetadataCountryCode":"DE","PreferredMetadataLanguage":"en"}'
        curl -sf $J/Startup/User >/dev/null   # wizard needs the default user loaded first
        curl -sf -X POST $J/Startup/User -H "Content-Type: application/json" \
          -d "$(jq -cn --arg p "$ADMIN_PASS" '{Name:"admin", Password:$p}')"
        curl -sf -X POST $J/Startup/Complete
      fi

      # Jellyfin 12 only accepts the Authorization header (no X-Emby-*, no api_key).
      HDR='Authorization: MediaBrowser Client="homelab", Device="setup", DeviceId="homelab-setup", Version="1.0"'
      login() {
        curl -sf -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "$HDR" \
          -d "$(jq -cn --arg p "$1" '{Username:"admin", Pw:$p}')" | jq -r '.AccessToken // empty'
      }
      TOKEN=$(login "$ADMIN_PASS")
      api() { curl -sf -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "Content-Type: application/json" "$@"; }
      # older installs were created with admin/admin: move them to the generated password.
      if [ -z "$TOKEN" ] && TOKEN=$(login admin) && [ -n "$TOKEN" ]; then
        ADMIN_ID=$(api $J/Users/Me | jq -r .Id)
        api -X POST "$J/Users/$ADMIN_ID/Password" -d "$(jq -cn --arg p "$ADMIN_PASS" '{CurrentPw:"admin", NewPw:$p}')"
        TOKEN=$(login "$ADMIN_PASS")
        echo "admin moved off the default password"
      fi
      [ -n "$TOKEN" ] || { echo "Jellyfin admin login failed"; exit 1; }

      # API key shared by Homepage, Janitorr, Jellyseerr wiring and Hermes.
      KEY=$(api $J/Auth/Keys | jq -r '[.Items[] | select(.AppName=="homelab")][0].AccessToken // empty')
      if [ -z "$KEY" ]; then
        api -X POST "$J/Auth/Keys?app=homelab"
        KEY=$(api $J/Auth/Keys | jq -r '[.Items[] | select(.AppName=="homelab")][0].AccessToken // empty')
      fi
      [ -n "$KEY" ] && echo -n "$KEY" > ${T}/jellyfin-key.token

      # libraries on the shared media layout.
      have=$(api $J/Library/VirtualFolders | jq -r '.[].Name')
      lib() { # name collectionType path
        echo "$have" | grep -qx "$1" && return 0
        api -X POST "$J/Library/VirtualFolders?name=$1&collectionType=$2&paths=$3&refreshLibrary=true" \
          -d '{"LibraryOptions":{"EnableRealtimeMonitor":true}}' && echo "library $1 created"
      }
      lib Movies movies /data/media/movies
      lib Shows tvshows /data/media/tv
      lib Anime tvshows /data/media/anime

      # Janitorr needs a real user with deletion rights, not only an API key.
      [ -s ${T}/janitorr-pass.token ] || openssl rand -hex 16 | tr -d '\n' > ${T}/janitorr-pass.token
      JPASS=$(cat ${T}/janitorr-pass.token)
      UID_J=$(api $J/Users | jq -r '.[] | select(.Name=="janitorr") | .Id')
      if [ -z "$UID_J" ]; then
        UID_J=$(api -X POST $J/Users/New -d "$(jq -cn --arg p "$JPASS" '{Name:"janitorr", Password:$p}')" | jq -r .Id)
      fi
      POLICY=$(api "$J/Users/$UID_J" | jq -c '.Policy | .IsAdministrator=true | .EnableContentDeletion=true | .IsHidden=true')
      api -X POST "$J/Users/$UID_J/Policy" -d "$POLICY"
    '';
  };

  # render Janitorr configs from the API keys the other VMs export. Waits until
  # all of them exist (the *arrs and Jellyseerr may come up later).
  systemd.services.janitorr-config = {
    description = "Render Janitorr configuration from exported API keys";
    after = [ "jellyfin-setup.service" ];
    requires = [ "jellyfin-setup.service" ];
    before = [ "podman-janitorr.service" "podman-janitorr-stats.service" ];
    requiredBy = [ "podman-janitorr.service" "podman-janitorr-stats.service" ];
    path = [ pkgs.coreutils pkgs.gnused ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 120; };
    script = ''
      for k in radarr-key sonarr-key jellyfin-key jellyseerr-key janitorr-pass; do
        [ -s ${T}/$k.token ] || { echo "waiting for ${T}/$k.token"; exit 1; }
      done
      render() {
        sed -e "s|@RADARR@|$(cat ${T}/radarr-key.token)|" \
            -e "s|@SONARR@|$(cat ${T}/sonarr-key.token)|" \
            -e "s|@JELLYFIN@|$(cat ${T}/jellyfin-key.token)|" \
            -e "s|@JELLYSEERR@|$(cat ${T}/jellyseerr-key.token)|" \
            -e "s|@JANITORR_PASS@|$(cat ${T}/janitorr-pass.token)|" "$1" > "$2.tmp"
        chmod 600 "$2.tmp"; chown 1000:1000 "$2.tmp"; mv "$2.tmp" "$2"
      }
      render ${janitorrConfig} /var/lib/janitorr/application.yml
      render ${statsConfig} /var/lib/janitorr/stats.yml
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
