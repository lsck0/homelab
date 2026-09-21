{ lib, pkgs, nasMount, ... }:
let
  T = "/var/lib/homepage-tokens";

  # public indexers added to Prowlarr on first run (Prowlarr definition names).
  # nyaasi covers anime, knaben is a meta-index. eztv answers 451 (blocked for
  # legal reasons) from Germany. Add private trackers in the Prowlarr UI; they
  # sync to every *arr automatically.
  indexers = [ "nyaasi" "yts" "thepiratebay" "limetorrents" "Knaben" ];

  arrWire = pkgs.writeShellScript "arr-wire" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnugrep ]}"
    export INDEXERS=${lib.escapeShellArg (lib.concatStringsSep " " indexers)}
    ${builtins.readFile ../scripts/arr-wire.sh}
  '';

  recyclarrTemplate = pkgs.writeText "recyclarr.yml.tmpl" ''
    radarr:
      main:
        base_url: http://10.100.0.130
        api_key: @RADARR@
        quality_definition:
          type: movie
    sonarr:
      main:
        base_url: http://10.100.0.131
        api_key: @SONARR@
        quality_definition:
          type: series
  '';
in {
  networking.hostName = "vm-133";

  # media automation host, no web UI:
  #   arr-wire   connects qBittorrent/Prowlarr/Jellyseerr/Bazarr to the *arrs
  #   recyclarr  syncs TRaSH-guide quality definitions into Radarr/Sonarr
  # Both read the API keys the other VMs export to the NAS token dir.
  fileSystems = nasMount T "homepage-tokens";

  systemd.services.arr-wire = {
    description = "Wire the media stack (*arr, qBittorrent, Prowlarr, Jellyseerr, Bazarr)";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
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
    path = [ pkgs.recyclarr pkgs.gnused pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      for k in radarr sonarr; do
        [ -s ${T}/$k-key.token ] || { echo "recyclarr: $k API key not exported yet, skipping"; exit 0; }
      done
      conf=$(mktemp --suffix=.yml); trap 'rm -f "$conf"' EXIT
      sed -e "s|@RADARR@|$(cat ${T}/radarr-key.token)|" -e "s|@SONARR@|$(cat ${T}/sonarr-key.token)|" \
        ${recyclarrTemplate} > "$conf"
      recyclarr sync --config "$conf"
    '';
  };
  systemd.timers.recyclarr-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "1d"; Persistent = true; };
  };
}
