{ config, pkgs, nasMount, nasPath, retry, ... }:
let
  T = "/var/lib/homepage-tokens";

  # janitorr: delete media unwatched this long
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
        url: "http://10.100.0.131"
        api-key: "@SONARR@"
        delete-empty-shows: true
        determine-age-by: most_recent
      radarr:
        enabled: true
        url: "http://10.100.0.130"
        api-key: "@RADARR@"
        only-delete-files: false
        determine-age-by: most_recent
      bazarr:
        enabled: false
      jellyfin:
        enabled: true
        url: "http://10.100.0.134"
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
        url: "http://10.100.0.128"
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
      base-url: http://10.100.0.134
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
  networking.hostName = "vm-134";

  # jellyfin db local (sqlite on nfs), nas keeps a copy
  fileSystems = nasMount "/var/lib/janitorr" "janitorr"
    // nasMount "/srv/jellyfin-nas" "jellyfin"
    // nasPath "/data" "bulk"
    // nasMount T "homepage-tokens";

  # fresh disk: restore from the NAS copy
  systemd.services.jellyfin-seed = {
    before = [ "podman-jellyfin.service" ];
    requiredBy = [ "podman-jellyfin.service" ];
    unitConfig.RequiresMountsFor = [ "/srv/jellyfin-nas" ];
    unitConfig.ConditionPathExists = "!/var/lib/jellyfin/config";
    path = [ pkgs.rsync ];
    serviceConfig.Type = "oneshot";
    script = "rsync -a /srv/jellyfin-nas/ /var/lib/jellyfin/";
  };

  systemd.services.jellyfin-mirror = {
    startAt = "01:15";
    unitConfig.RequiresMountsFor = [ "/srv/jellyfin-nas" ];
    path = [ pkgs.rsync pkgs.sqlite ];
    serviceConfig.Type = "oneshot";
    script = ''
      rsync -a --delete --exclude cache --exclude 'config/data/*.db*' /var/lib/jellyfin/ /srv/jellyfin-nas/
      for db in /var/lib/jellyfin/config/data/*.db; do
        sqlite3 "$db" ".backup /srv/jellyfin-nas/config/data/$(basename "$db")"
      done
    '';
  };

  virtualisation.oci-containers.containers = {
    jellyfin = {
      image = "jellyfin/jellyfin:12.1";
      ports = [ "80:8096" ];
      volumes = [
        "/var/lib/jellyfin/config:/config"
        "/var/lib/jellyfin/cache:/cache"
        "/data/media:/data/media:ro"
      ];
      environment.JELLYFIN_PublishedServerUrl = "https://jellyfin.lsck0.dev";
    };

    janitorr-stats = {
      image = "ghcr.io/schaka/janitorr-stats:v0.2.6-sqlite";
      volumes = [
        "/var/lib/janitorr/stats.yml:/work/config/application.yml:ro"
        "/var/lib/janitorr/stats:/data"
      ];
      extraOptions = [ "--network=host" ];
    };

    janitorr = {
      image = "ghcr.io/schaka/janitorr:jvm-v2.2.1";
      user = "1000:1000";
      dependsOn = [ "janitorr-stats" ];
      volumes = [
        "/var/lib/janitorr/application.yml:/config/application.yml:ro"
        "/var/lib/janitorr/logs:/logs"
        "/data/media:/data/media"
        "/data/torrents:/data/torrents"
      ];
      # host network, avoid jellyfin's 8096/80
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

  # first run: admin, libraries, api key
  systemd.services.jellyfin-setup = {
    description = "Initialise Jellyfin (admin, libraries, API key, janitorr user)";
    after = [ "podman-jellyfin.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 60; };
    script = ''
      J=http://127.0.0.1:80
      ${retry} 90 2 curl -sf $J/health

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

      # jellyfin 12 only accepts the Authorization header
      HDR='Authorization: MediaBrowser Client="homelab", Device="setup", DeviceId="homelab-setup", Version="1.0"'
      login() {
        curl -sf -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "$HDR" \
          -d "$(jq -cn --arg p "$1" '{Username:"admin", Pw:$p}')" | jq -r '.AccessToken // empty'
      }
      TOKEN=$(login "$ADMIN_PASS")
      api() { curl -sf -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "Content-Type: application/json" "$@"; }
      # migrate old admin/admin installs
      if [ -z "$TOKEN" ] && TOKEN=$(login admin) && [ -n "$TOKEN" ]; then
        ADMIN_ID=$(api $J/Users/Me | jq -r .Id)
        api -X POST "$J/Users/$ADMIN_ID/Password" -d "$(jq -cn --arg p "$ADMIN_PASS" '{CurrentPw:"admin", NewPw:$p}')"
        TOKEN=$(login "$ADMIN_PASS")
        echo "admin moved off the default password"
      fi
      [ -n "$TOKEN" ] || { echo "Jellyfin admin login failed"; exit 1; }

      # shared by homepage, janitorr, jellyseerr, hermes
      KEY=$(api $J/Auth/Keys | jq -r '[.Items[] | select(.AppName=="homelab")][0].AccessToken // empty')
      if [ -z "$KEY" ]; then
        api -X POST "$J/Auth/Keys?app=homelab"
        KEY=$(api $J/Auth/Keys | jq -r '[.Items[] | select(.AppName=="homelab")][0].AccessToken // empty')
      fi
      [ -n "$KEY" ] && echo -n "$KEY" > ${T}/jellyfin-key.token

      # libraries; nfs has no inotify, arr imports trigger scans
      have=$(api $J/Library/VirtualFolders | jq -r '.[].Name')
      lib() { # name collectionType path
        echo "$have" | grep -qx "$1" && return 0
        api -X POST "$J/Library/VirtualFolders?name=$1&collectionType=$2&paths=$3&refreshLibrary=true" \
          -d '{"LibraryOptions":{"EnableRealtimeMonitor":true}}' && echo "library $1 created"
      }
      lib Movies movies /data/media/movies
      lib Shows tvshows /data/media/tv
      lib Anime tvshows /data/media/anime

      # new libraries have no metadata fetchers, fix every run
      fetchers() { # jq array of type names -> TypeOptions for those types
        jq -cn --argjson types "$1" '[$types[] | {
          Type: .,
          MetadataFetchers: ["TheMovieDb"], MetadataFetcherOrder: ["TheMovieDb"],
          ImageFetchers: ["TheMovieDb"],    ImageFetcherOrder: ["TheMovieDb"],
          ImageOptions: []
        }]'
      }
      api $J/Library/VirtualFolders | jq -c '.[]' | while read -r folder; do
        name=$(echo "$folder" | jq -r .Name)
        [ "$(echo "$folder" | jq -r '.LibraryOptions.EnableInternetProviders')" = true ] && continue
        case "$(echo "$folder" | jq -r .CollectionType)" in
          movies)  types='["Movie"]' ;;
          tvshows) types='["Series","Season","Episode"]' ;;
          *) continue ;;
        esac
        body=$(echo "$folder" | jq -c --argjson t "$(fetchers "$types")" \
          '{Id: .ItemId, LibraryOptions: (.LibraryOptions
             | .EnableInternetProviders = true
             | .TypeOptions = $t)}')
        api -X POST "$J/Library/VirtualFolders/LibraryOptions" -d "$body" \
          && echo "library $name: metadata fetching enabled"
      done

      # janitorr needs a real user that can delete
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

  # lldap account is the jellyfin account
  sops.secrets.lldap-admin-password = {};
  systemd.services.jellyfin-ldap = {
    description = "Point Jellyfin authentication at lldap (LDAP-Auth plugin)";
    after = [ "jellyfin-setup.service" ];
    requires = [ "jellyfin-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 120; };
    script = ''
      J=http://127.0.0.1:80
      ${retry} 90 2 curl -sf $J/health

      HDR='Authorization: MediaBrowser Client="homelab", Device="setup", DeviceId="homelab-setup", Version="1.0"'
      TOKEN=$(curl -sf -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "$HDR" \
        -d "$(jq -cn --arg p "$(cat ${T}/jellyfin-admin-pass.token)" '{Username:"admin", Pw:$p}')" \
        | jq -r '.AccessToken // empty')
      [ -n "$TOKEN" ] || { echo "Jellyfin admin login failed"; exit 1; }
      api() { curl -sf -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "Content-Type: application/json" "$@"; }

      plugin_id() { api $J/Plugins | jq -r '[.[] | select(.Name | test("LDAP"; "i"))][0].Id // empty'; }

      ID=$(plugin_id)
      if [ -z "$ID" ]; then
        echo "installing the LDAP Authentication plugin"
        api -X POST "$J/Packages/Installed/LDAP%20Authentication" >/dev/null \
          || { echo "plugin install request failed; leaving Jellyfin on local accounts"; exit 0; }
        # plugin config endpoint appears only after restart
        systemctl restart podman-jellyfin.service
        ${retry} 90 2 curl -sf $J/health
        TOKEN=$(curl -sf -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "$HDR" \
          -d "$(jq -cn --arg p "$(cat ${T}/jellyfin-admin-pass.token)" '{Username:"admin", Pw:$p}')" \
          | jq -r '.AccessToken // empty')
        for _ in $(seq 1 30); do ID=$(plugin_id); [ -n "$ID" ] && break; sleep 5; done
        [ -n "$ID" ] || { echo "plugin did not appear after restart"; exit 0; }
      fi

      # trust traefik, else redirect_uri is http:// and rejected
      NET=$(api $J/System/Configuration/network | jq -c '
        .KnownProxies = ["10.100.0.100"]
        | .PublishedServerUriBySubnet = ["all=https://jellyfin.lsck0.dev"]')
      if [ "$NET" != "$(api $J/System/Configuration/network | jq -c .)" ]; then
        api -X POST $J/System/Configuration/network -d "$NET" >/dev/null
        systemctl restart podman-jellyfin.service
        ${retry} 90 2 curl -sf $J/health
        TOKEN=$(login)
        echo "Jellyfin now trusts the internal Traefik as a proxy"
      fi

      api -X POST "$J/Plugins/$ID/Configuration" -d "$(jq -cn \
        --arg pass "$(cat ${config.sops.secrets.lldap-admin-password.path})" '{
        LdapServer: "10.100.0.102",
        LdapPort: 3890,
        UseSsl: false,
        UseStartTls: false,
        SkipSslVerify: true,
        LdapBindUser: "uid=admin,ou=people,dc=lsck0,dc=dev",
        LdapBindPassword: $pass,
        LdapBaseDn: "ou=people,dc=lsck0,dc=dev",
        LdapSearchFilter: "(|(memberOf=cn=admins,ou=groups,dc=lsck0,dc=dev)(memberOf=cn=app-jellyfin,ou=groups,dc=lsck0,dc=dev))",
        LdapAdminFilter: "(memberOf=cn=admins,ou=groups,dc=lsck0,dc=dev)",
        LdapSearchAttributes: "uid, cn, mail, displayName",
        LdapUsernameAttribute: "uid",
        LdapPasswordAttribute: "userPassword",
        CreateUsersFromLdap: true,
        AllowPassChange: false,
        EnableAllFolders: true,
        EnabledFolders: []
      }')" >/dev/null \
        && echo "Jellyfin authenticates against lldap" \
        || echo "writing the LDAP plugin configuration failed; configure it in the Jellyfin UI"
    '';
  };

  # browser sso via jellyfin-plugin-sso and authelia
  sops.secrets.jellyfin-oidc-secret = {};
  systemd.services.jellyfin-sso = {
    description = "Install and configure jellyfin-plugin-sso against Authelia";
    after = [ "jellyfin-ldap.service" ];
    requires = [ "jellyfin-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 120; };
    script = ''
      J=http://127.0.0.1:80
      ${retry} 90 2 curl -sf $J/health

      HDR='Authorization: MediaBrowser Client="homelab", Device="setup", DeviceId="homelab-setup", Version="1.0"'
      login() {
        curl -sf -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "$HDR" \
          -d "$(jq -cn --arg p "$(cat ${T}/jellyfin-admin-pass.token)" '{Username:"admin", Pw:$p}')" \
          | jq -r '.AccessToken // empty'
      }
      TOKEN=$(login)
      [ -n "$TOKEN" ] || { echo "Jellyfin admin login failed"; exit 1; }
      api() { curl -sf -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "Content-Type: application/json" "$@"; }

      MANIFEST=https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json
      if ! api $J/Repositories | jq -e --arg u "$MANIFEST" 'any(.[]; .Url == $u)' >/dev/null; then
        REPOS=$(api $J/Repositories | jq -c --arg u "$MANIFEST" '. + [{Name:"jellyfin-plugin-sso", Url:$u, Enabled:true}]')
        api -X POST $J/Repositories -d "$REPOS" >/dev/null && echo "SSO plugin repository added"
      fi

      plugin_id() { api $J/Plugins | jq -r '[.[] | select(.Name | test("SSO"; "i"))][0].Id // empty'; }
      ID=$(plugin_id)
      if [ -z "$ID" ]; then
        echo "installing the SSO Authentication plugin"
        api -X POST "$J/Packages/Installed/SSO%20Authentication" >/dev/null \
          || { echo "plugin install request failed; Jellyfin keeps its own login"; exit 1; }
        systemctl restart podman-jellyfin.service
        ${retry} 90 2 curl -sf $J/health
        TOKEN=$(login)
        for _ in $(seq 1 30); do ID=$(plugin_id); [ -n "$ID" ] && break; sleep 5; done
        # fail so a slow install gets retried
        [ -n "$ID" ] || { echo "SSO plugin did not appear after restart"; exit 1; }
      fi

      api -X POST "$J/Plugins/$ID/Configuration" -d "$(jq -cn \
        --arg secret "$(cat ${config.sops.secrets.jellyfin-oidc-secret.path})" '{
        SamlConfigs: {},
        OidConfigs: {
          authelia: {
            OidEndpoint: "https://auth.lsck0.dev",
            OidClientId: "jellyfin",
            OidSecret: $secret,
            Enabled: true,
            EnableAuthorization: true,
            EnableAllFolders: true,
            EnabledFolders: [],
            AdminRoles: ["admins"],
            Roles: ["media"],
            EnableFolderRoles: false,
            RoleClaim: "groups",
            OidScopes: ["groups"],
            CanonicalLinks: {},
            DisableHttps: false,
            # authelia client is not registered for par
            DisablePushedAuthorization: true,
            DoNotValidateEndpoints: false,
            DoNotValidateIssuerName: false
          }
        }
      }')" >/dev/null \
        && echo "Jellyfin SSO points at Authelia" \
        || { echo "writing the SSO plugin configuration failed"; exit 1; }
    '';
  };

  # render janitorr configs from exported api keys
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
