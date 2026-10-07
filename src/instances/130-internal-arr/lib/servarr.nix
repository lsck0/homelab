# the *arr apps: one linuxserver container shape, state on the guest's disk with a nas copy (modules/local-state)
#
# A servarr app (radarr, sonarr, lidarr, prowlarr) takes its settings and its api key, the sops secret <name>-key,
# from its <NAME>__<SECTION>__<KEY> environment, which overrides config.xml (the servarr Options pattern; bootstrap
# AddEnvironmentVariables in every pinned image). Bazarr has no such override: it mints its own key, which its setup
# exports as the lab token <name>-key.
{ config, lib, pkgs, site, catalog, nasPath, retry, setupUnit, ... }:
let
  cfg = config.homelab.servarr;

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
        description = "xml: a servarr app, configured through its environment. yaml: bazarr, configured in config/config.yaml.";
      };
    };
  });
  servarrApps = lib.filterAttrs (_: app: app.configFormat == "xml") cfg;
  bazarrApps = lib.filterAttrs (_: app: app.configFormat == "yaml") cfg;

  # authelia gates the route, local callers skip auth
  servarrSettings = name: let prefix = lib.toUpper name; in {
    "${prefix}__AUTH__METHOD" = "External";
    "${prefix}__AUTH__REQUIRED" = "DisabledForLocalAddresses";
    "${prefix}__LOG__ANALYTICSENABLED" = "False";
  };
  keySecretOf = name: "${name}-key";

  # the databases and what each app regenerates (logs, posters), relative to its state dir
  sqliteOf = { xml = [ "*.db" ]; yaml = [ "db/*.db" ]; };
  regeneratedOf = { xml = [ "logs" "MediaCover" ]; yaml = [ "log" "cache" ]; };
in {
  options.homelab.servarr = lib.mkOption {
    type = lib.types.attrsOf appType;
    default = {};
    description = "Servarr-family apps on this VM, keyed by name (also the NAS data share and the key's name).";
  };

  config = lib.mkIf (cfg != {}) {
    # a host's own mount of the same path wins
    homelab.nasMounts = lib.mapAttrs (_: lib.mkDefault) (nasPath "/data" "bulk");

    # the share names are the apps' names, as when the state lived on the share itself
    homelab.localState = lib.mapAttrs (name: app: {
      path = stateDirOf name;
      unit = "podman-${name}";
      sqlite = sqliteOf.${app.configFormat};
      exclude = regeneratedOf.${app.configFormat};
    }) cfg;

    sops.secrets = lib.mapAttrs' (name: _: lib.nameValuePair (keySecretOf name) { }) servarrApps;
    sops.templates = lib.mapAttrs' (name: _: lib.nameValuePair "${name}.env" {
      content = "${lib.toUpper name}__AUTH__APIKEY=${config.sops.placeholder.${keySecretOf name}}\n";
      restartUnits = [ "podman-${name}.service" ];
    }) servarrApps;

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
      } // lib.optionalAttrs (app.configFormat == "xml") (servarrSettings name);
      environmentFiles = lib.optional (app.configFormat == "xml") config.sops.templates."${name}.env".path;
      # 210 to 240 MiB idle measured, imports and scans spike
      extraOptions = [ "--memory=512m" ];
    }) cfg;

    systemd.tmpfiles.rules = lib.mapAttrsToList (name: _: "d ${stateDirOf name} 0750 ${uid} ${uid} -") cfg;

    # analytics off, edited while stopped: bazarr rewrites its config on shutdown
    systemd.services = lib.mapAttrs' (name: _: lib.nameValuePair "${name}-setup" (setupUnit {
      description = "Configure ${name} and export its API key";
      after = [ "podman-${name}.service" ];
      path = [ pkgs.systemd pkgs.yq-go ];
      script = ''
        conf=${stateDirOf name}/config/config.yaml
        ${retry} 90 2 test -f "$conf"
        if [ "$(yq '.analytics.enabled' "$conf")" != false ]; then
          systemctl stop podman-${name}.service
          yq -i '.analytics.enabled = false' "$conf"
          systemctl start podman-${name}.service
        fi
        yq -e '.auth.apikey' "$conf" | tr -d '\n' | token_write ${keySecretOf name}
      '';
    })) bazarrApps;
  };
}
