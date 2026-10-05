{ config, lib, pkgs, nasMount, nasPath, retry, ... }:
let
  cfg = config.homelab.servarr;
  tokens = config.homelab.tokens.dir;

  appType = lib.types.submodule {
    options = {
      image = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption {
        type = lib.types.port;
        description = "Port the app listens on, published as is on the VM (routes.nix points here).";
      };
      configFormat = lib.mkOption {
        type = lib.types.enum [ "xml" "yaml" ];
        default = "xml";
        description = "xml: the *arr config.xml, auth delegated to Authelia. yaml: bazarr's config/config.yaml.";
      };
    };
  };

  # authelia gates the route, local callers skip auth
  xmlSettings = {
    AuthenticationMethod = "External";
    AuthenticationRequired = "DisabledForLocalAddresses";
    AnalyticsEnabled = "False";
  };

  # per format: sets $conf and $key; edits run stopped, the apps rewrite their config on shutdown
  readConfig = {
    xml = name: ''
      conf=/var/lib/${name}/config.xml
      ${retry} 90 2 test -f "$conf"
      xml_set() { # element value
        if grep -q "<$1>" "$conf"; then sed -i "s|<$1>.*</$1>|<$1>$2</$1>|" "$conf"
        else sed -i "s|</Config>|  <$1>$2</$1>\n</Config>|" "$conf"; fi
      }
      settings="${lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "${k}=${v}") xmlSettings)}"
      stale=false
      for kv in $settings; do grep -q "<''${kv%%=*}>''${kv#*=}</" "$conf" || stale=true; done
      if $stale; then
        systemctl stop podman-${name}.service
        for kv in $settings; do xml_set "''${kv%%=*}" "''${kv#*=}"; done
        systemctl start podman-${name}.service
      fi
      key=$(grep -oP '<ApiKey>\K[^<]+' "$conf" || true)
    '';
    yaml = name: ''
      conf=/var/lib/${name}/config/config.yaml
      ${retry} 90 2 test -f "$conf"
      if [ "$(yq '.analytics.enabled' "$conf")" != false ]; then
        systemctl stop podman-${name}.service
        yq -i '.analytics.enabled = false' "$conf"
        systemctl start podman-${name}.service
      fi
      key=$(yq '.auth.apikey' "$conf")
    '';
  };
in {
  # the *arr apps share one linuxserver container shape
  options.homelab.servarr = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = {};
    description = "Servarr-family apps on this VM, keyed by name (also the NAS data dir and token name).";
  };

  config = lib.mkIf (cfg != {}) {
    # a host's own mount of the same path wins
    fileSystems = lib.mkMerge ([
      (lib.mapAttrs (_: lib.mkDefault) (
        nasPath "/data" "bulk"
      ))
    ] ++ lib.mapAttrsToList (name: _: nasMount "/var/lib/${name}" name) cfg);

    virtualisation.oci-containers.containers = lib.mapAttrs (name: app: {
      inherit (app) image;
      ports = [ "${toString app.port}:${toString app.port}" ];
      volumes = [
        "/var/lib/${name}:/config"
        # one bind so imports can hardlink
        "/data:/data"
      ];
      environment = {
        PUID = "1000";
        PGID = "1000";
        TZ = "Europe/Berlin";
      };
      # 210 to 240 MiB idle measured, imports and scans spike
      extraOptions = [ "--memory=512m" ];
    }) cfg;

    systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: "d /var/lib/${name} 0750 1000 1000 -") cfg;

    systemd.services = lib.mapAttrs' (name: app: lib.nameValuePair "${name}-setup" {
      description = "Configure ${name} and export its API key";
      after = [ "podman-${name}.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils pkgs.yq-go ];
      # config and token live on the nas, retry until it answers
      startLimitIntervalSec = 0;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 30; };
      script = ''
        ${readConfig.${app.configFormat} name}
        [ -n "$key" ] && [ "$key" != null ] || { echo "no API key in $conf yet"; exit 1; }
        [ "$(cat ${tokens}/${name}-key.token 2>/dev/null)" = "$key" ] || echo -n "$key" > ${tokens}/${name}-key.token
      '';
    }) cfg;

    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: app: app.port) cfg;

    # local addresses skip auth, so guard the port
    homelab.ingressOnly = {
      ports = lib.mapAttrsToList (_: app: app.port) cfg;
      extraSources = map (id: "10.100.0.${toString id}/32")
        [ 128 134 ];
    };
  };
}
