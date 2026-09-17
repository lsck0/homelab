{ config, lib, pkgs, nasMount, nasPath, ... }:
let
  cfg = config.homelab.servarr;
  tokens = "/var/lib/homepage-tokens";

  appType = lib.types.submodule {
    options = {
      image = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption {
        type = lib.types.port;
        description = "Port the app listens on inside the container.";
      };
      hostPort = lib.mkOption {
        type = lib.types.port;
        default = 80;
        description = "Port published on the VM (routes.nix points here).";
      };
    };
  };
in {
  # Radarr/Sonarr/Lidarr/Prowlarr/Bookshelf all share one shape: a linuxserver-
  # style container, config on the NAS, auth delegated to Authelia, and an API
  # key exported to the NAS token dir. That key is what Homepage widgets,
  # the *arr wiring on vm-132, Janitorr, Jellyseerr and Hermes use.
  #
  # media layout (same path in every container, so imports can be moved and
  # Janitorr/Jellyfin see the files where the *arrs put them):
  #   /data/media/{movies,tv,anime,music,books,manga,audiobooks,leaving-soon}
  #   /data/torrents   qBittorrent download dir
  options.homelab.servarr = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = {};
    description = "Servarr-family apps on this VM, keyed by name (also the NAS data dir and token name).";
  };

  config = lib.mkIf (cfg != {}) {
    # mkDefault: a host that mounts the same path itself (e.g. the token dir)
    # wins instead of merging two definitions of one mount.
    fileSystems = lib.mkMerge ([
      (lib.mapAttrs (_: lib.mkDefault) (
        nasPath "/data/media" "media" // nasPath "/data/torrents" "torrents" // nasMount tokens "homepage-tokens"
      ))
    ] ++ lib.mapAttrsToList (name: _: nasMount "/var/lib/${name}" name) cfg);

    virtualisation.oci-containers.containers = lib.mapAttrs (name: app: {
      inherit (app) image;
      ports = [ "${toString app.hostPort}:${toString app.port}" ];
      volumes = [
        "/var/lib/${name}:/config"
        "/data/media:/data/media"
        "/data/torrents:/data/torrents"
      ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "Europe/Berlin";
      };
    }) cfg;

    systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: "d /var/lib/${name} 0750 1000 1000 -") cfg;

    systemd.services = lib.mapAttrs' (name: _: lib.nameValuePair "${name}-setup" {
      description = "Delegate ${name} auth to Authelia and export its API key";
      after = [ "podman-${name}.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = ''
        conf=/var/lib/${name}/config.xml
        for i in $(seq 1 90); do [ -f "$conf" ] && break; sleep 2; done
        [ -f "$conf" ] || { echo "$conf not created"; exit 1; }

        # edit while stopped: the app may write its config back on shutdown.
        if ! grep -q '<AuthenticationMethod>External</AuthenticationMethod>' "$conf"; then
          systemctl stop podman-${name}.service
          sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>External</AuthenticationMethod>|' "$conf"
          grep -q '<AuthenticationMethod>' "$conf" \
            || sed -i 's|</Config>|  <AuthenticationMethod>External</AuthenticationMethod>\n</Config>|' "$conf"
          sed -i 's|<AuthenticationRequired>.*</AuthenticationRequired>|<AuthenticationRequired>DisabledForLocalAddresses</AuthenticationRequired>|' "$conf"
          systemctl start podman-${name}.service
        fi

        key=$(grep -oP '<ApiKey>\K[^<]+' "$conf")
        [ -n "$key" ] && [ "$(cat ${tokens}/${name}-key.token 2>/dev/null)" != "$key" ] \
          && echo -n "$key" > ${tokens}/${name}-key.token
        true
      '';
    }) cfg;

    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: app: app.hostPort) cfg;
  };
}
