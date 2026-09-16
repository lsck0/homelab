{ config, pkgs, ... }: {
  networking.hostName = "vm-138";

  # Recyclarr — syncs TRaSH-guide quality profiles/custom formats into Sonarr
  # and Radarr on a schedule. No web UI. The two arr API keys come from sops
  # (fill radarr-api-key / sonarr-api-key, then this starts working); the config
  # is rendered at deploy time so the keys never land in the Nix store.
  sops.secrets.radarr-api-key = {};
  sops.secrets.sonarr-api-key = {};
  sops.templates."recyclarr.yml".content = ''
    radarr:
      main:
        base_url: http://10.100.0.119
        api_key: ${config.sops.placeholder.radarr-api-key}
        quality_definition:
          type: movie
    sonarr:
      main:
        base_url: http://10.100.0.120
        api_key: ${config.sops.placeholder.sonarr-api-key}
        quality_definition:
          type: series
  '';

  systemd.services.recyclarr-sync = {
    description = "Recyclarr sync to Sonarr/Radarr";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.recyclarr ];
    serviceConfig = {
      Type = "oneshot";
      # Skip cleanly until both API keys are filled.
      ExecStart = pkgs.writeShellScript "recyclarr-sync" ''
        grep -q 'api_key: *$' ${config.sops.templates."recyclarr.yml".path} && {
          echo "recyclarr: API keys not set yet, skipping"; exit 0; }
        ${pkgs.recyclarr}/bin/recyclarr sync --config ${config.sops.templates."recyclarr.yml".path}
      '';
    };
  };

  systemd.timers.recyclarr-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10min"; OnUnitActiveSec = "1d"; Persistent = true; };
  };
}
