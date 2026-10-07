{ config, lib, pkgs, inventory, site, catalog, nasMount, nasPath, retry, setupUnit, ... }:
let
  cfg = config.homelab.servarr;
  net = import ../../../modules/net.nix { inherit lib inventory site; };

  # they call the arrs' apis directly: jellyseerr sends approved requests, janitorr deletes through them
  directClients = [ "128" "134" ];
  stateDirOf = name: "/var/lib/${name}";
  # linuxserver's PUID/PGID, the owner of the state dirs
  uid = "1000";

  appType = lib.types.submodule ({ name, ... }: {
    options = {
      image = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption {
        type = lib.types.port;
        default = catalog.internal.${name}.port;
        defaultText = lib.literalExpression "catalog.internal.<name>.port";
        description = "Port the app listens on, published as is on the VM; its route in the instance's instance.nix says which.";
      };
      configFormat = lib.mkOption {
        type = lib.types.enum [ "xml" "yaml" ];
        default = "xml";
        description = "xml: the *arr config.xml, auth delegated to Authelia. yaml: bazarr's config/config.yaml.";
      };
    };
  });

  # authelia gates the route, local callers skip auth
  xmlSettings = {
    AuthenticationMethod = "External";
    AuthenticationRequired = "DisabledForLocalAddresses";
    AnalyticsEnabled = "False";
  };

  # per format: sets $conf and defines key_read; edits run stopped, the apps rewrite their config on shutdown
  readConfig = {
    xml = name: ''
      conf=${stateDirOf name}/config.xml
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
      key_read() { grep -oP '<ApiKey>\K[^<]+' "$conf"; }
    '';
    yaml = name: ''
      conf=${stateDirOf name}/config/config.yaml
      ${retry} 90 2 test -f "$conf"
      if [ "$(yq '.analytics.enabled' "$conf")" != false ]; then
        systemctl stop podman-${name}.service
        yq -i '.analytics.enabled = false' "$conf"
        systemctl start podman-${name}.service
      fi
      key_read() { yq -e '.auth.apikey' "$conf"; }
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
    homelab.nasMounts = lib.mkMerge ([
      (lib.mapAttrs (_: lib.mkDefault) (
        nasPath "/data" "bulk"
      ))
    ] ++ lib.mapAttrsToList (name: _: nasMount (stateDirOf name) name) cfg);

    virtualisation.oci-containers.containers = lib.mapAttrs (name: app: {
      inherit (app) image;
      ports = [ "${toString app.port}:${toString app.port}" ];
      volumes = [
        "${stateDirOf name}:/config"
        # one bind so imports can hardlink
        "/data:/data"
      ];
      environment = {
        PUID = uid;
        PGID = uid;
        TZ = site.timeZone;
      };
      # 210 to 240 MiB idle measured, imports and scans spike
      extraOptions = [ "--memory=512m" ];
    }) cfg;

    systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: "d ${stateDirOf name} 0750 ${uid} ${uid} -") cfg;

    systemd.services = lib.mapAttrs' (name: app: lib.nameValuePair "${name}-setup" (setupUnit {
      description = "Configure ${name} and export its API key";
      after = [ "podman-${name}.service" ];
      path = [ pkgs.gnused pkgs.gnugrep pkgs.systemd pkgs.coreutils pkgs.yq-go ];
      script = ''
        ${readConfig.${app.configFormat} name}
        key=$(key_read) || { echo "no API key in $conf yet"; exit 1; }
        printf '%s' "$key" | token_write ${name}-key
      '';
    })) cfg;

    networking.firewall.allowedTCPPorts = lib.mapAttrsToList (_: app: app.port) cfg;

    # local addresses skip auth, so guard the port
    homelab.ingressOnly = {
      ports = lib.mapAttrsToList (_: app: app.port) cfg;
      extraSources = map net.hostSource directClients;
    };
  };
}
