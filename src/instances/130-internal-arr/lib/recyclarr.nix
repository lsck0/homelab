# recyclarr and arr-wire: no web ui, they configure and link the media stack
{ config, lib, pkgs, inventory, catalog, site, ... }:
let
  # the router's tor socks port isolated per destination
  torSocksIsolatedPort = (import ../../../modules/tor-ports.nix).socksIsolated;

  ipOf = name: inventory.${toString catalog.internal.${name}.vmid}.ip;
  portOf = name: toString catalog.internal.${name}.port;
  publicUrlOf = name: "https://${catalog.internal.${name}.host}.${site.domain}";

  # public indexers seeded into prowlarr on first run
  indexers = [
    "nyaasi" "yts" "thepiratebay" "limetorrents" "Knaben"
    "ebookbay" "internetarchive" "postman"
  ];

  # arr-wire.sh's inputs; src/tests/media-stack.sh runs the same script with its own
  arrWireEnvironment = {
    TOKEN_DIR = config.homelab.tokens.dir;
    INDEXERS = lib.concatStringsSep " " indexers;
    QBIT_HOST = ipOf "qbittorrent";         QBIT_PORT = portOf "qbittorrent";
    PROWLARR_HOST = ipOf "prowlarr";        PROWLARR_PORT = portOf "prowlarr";
    RADARR_HOST = ipOf "radarr";            RADARR_PORT = portOf "radarr";
    SONARR_HOST = ipOf "sonarr";            SONARR_PORT = portOf "sonarr";
    LIDARR_HOST = ipOf "lidarr";            LIDARR_PORT = portOf "lidarr";
    JELLYFIN_HOST = ipOf "jellyfin";        JELLYFIN_PORT = portOf "jellyfin";
    JELLYSEERR_URL = "http://${ipOf "jellyseerr"}:${portOf "jellyseerr"}";
    BAZARR_URL = "http://${ipOf "bazarr"}:${portOf "bazarr"}";
    RADARR_PUBLIC_URL = publicUrlOf "radarr";
    SONARR_PUBLIC_URL = publicUrlOf "sonarr";
    # the router's address in this guest's zone
    TOR_HOST = inventory."130".gateway;
    TOR_PORT = toString torSocksIsolatedPort;
    JELLYSEERR_ADMIN_EMAIL = "admin@${site.domain}";
  };

  arrWire = pkgs.writeShellScript "arr-wire" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ]}"
    ${builtins.readFile ./arr-wire.sh}
  '';

  recyclarrTemplate = pkgs.writeText "recyclarr.yml.tmpl" ''
    radarr:
      main:
        base_url: http://127.0.0.1:${portOf "radarr"}
        api_key: @RADARR@
        quality_definition:
          type: movie
    sonarr:
      main:
        base_url: http://127.0.0.1:${portOf "sonarr"}
        api_key: @SONARR@
        quality_definition:
          type: series
  '';
in {
  # arr-wire links the arrs to jellyfin and the download client
  homelab.tokens.reads = [ "jellyfin-key-arr" "jellyfin-admin-pass" "qbittorrent-pass" ];

  systemd.services.arr-wire = {
    description = "Wire the media stack (*arr, qBittorrent, Prowlarr, Jellyseerr, Bazarr)";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    environment = arrWireEnvironment;
    serviceConfig = { Type = "oneshot"; ExecStart = arrWire; };
  };
  systemd.timers.arr-wire = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "3min"; OnUnitActiveSec = "10min"; };
  };

  systemd.services.recyclarr-sync = {
    description = "Recyclarr sync to Sonarr/Radarr";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.recyclarr pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RuntimeDirectory = "recyclarr-sync"; RuntimeDirectoryMode = "0700"; };
    script = ''
      set -euo pipefail
      T=${config.homelab.tokens.dir}
      for k in radarr sonarr; do
        [ -s "$T/$k-key.token" ] || { echo "recyclarr: $k API key not exported yet, skipping"; exit 0; }
      done
      # substituted in the shell: the keys never pass through argv
      conf=$(cat ${recyclarrTemplate})
      conf=''${conf//@RADARR@/$(cat "$T/radarr-key.token")}
      conf=''${conf//@SONARR@/$(cat "$T/sonarr-key.token")}
      printf '%s\n' "$conf" > "$RUNTIME_DIRECTORY/recyclarr.yml"
      recyclarr sync --config "$RUNTIME_DIRECTORY/recyclarr.yml"
    '';
  };
  systemd.timers.recyclarr-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "1d"; Persistent = true; };
  };
}
