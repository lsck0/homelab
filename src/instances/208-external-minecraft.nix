{ config, pkgs, nasMount, ... }:
let
  data = "/var/lib/minecraft";
  # runtime server type/modpack
  modpackEnv = "${data}/modpack.env";
  defaultModpack = ''
    TYPE=VANILLA
    VERSION=LATEST
    LEVEL=vanilla
  '';

  # mc-modpack <modrinth url|slug|curseforge url|vanilla> [version]
  mcModpack = pkgs.writeShellScriptBin "mc-modpack" ''
    set -euo pipefail
    arg="''${1:-}"; version="''${2:-LATEST}"
    if [ -z "$arg" ]; then
      echo "current:"; cat ${modpackEnv}
      echo; echo "usage: mc-modpack <modrinth url|modrinth slug|curseforge url|vanilla> [minecraft version]"
      exit 0
    fi
    slug=$(basename "''${arg%/}")
    case "$arg" in
      vanilla)
        env="TYPE=VANILLA"; slug=vanilla ;;
      *curseforge.com*)
        # most packs need CF_API_KEY in rcon.env
        env="TYPE=AUTO_CURSEFORGE
    CF_PAGE_URL=$arg" ;;
      *)
        env="TYPE=MODRINTH
    MODRINTH_MODPACK=$arg" ;;
    esac
    printf '%s\nVERSION=%s\nLEVEL=%s\n' "$env" "$version" "$slug" | sed 's/^ *//' > ${modpackEnv}.tmp
    mv ${modpackEnv}.tmp ${modpackEnv}
    echo ">>> modpack set to $arg (world: $slug), restarting server (first start downloads the pack)"
    systemctl restart podman-minecraft.service
  '';

  # mc-rcon <command...>
  mcRcon = pkgs.writeShellScriptBin "mc-rcon" ''
    exec ${pkgs.podman}/bin/podman exec minecraft rcon-cli "$@"
  '';
in {
  networking.hostName = "vm-208";

  fileSystems = nasMount data "minecraft"
    // nasMount "/var/lib/minecraft-modpacks" "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = {};

  environment.systemPackages = [ mcModpack mcRcon ];

  systemd.services.minecraft-env = {
    description = "Generate Minecraft env files";
    before = [ "podman-minecraft.service" ];
    requiredBy = [ "podman-minecraft.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      echo "RCON_PASSWORD=$(cat ${config.sops.secrets.minecraft-rcon-password.path})" > ${data}/rcon.env
      chmod 600 ${data}/rcon.env
      [ -s ${modpackEnv} ] || printf '%s' ${pkgs.lib.escapeShellArg defaultModpack} > ${modpackEnv}
    '';
  };

  virtualisation.oci-containers.containers.minecraft = {
    # java25: vanilla 26.3 needs it
    image = "itzg/minecraft-server:2026.9.1-java25";
    ports = [ "25565:25565" "25575:25575" ];
    extraOptions = [ "--dns=1.1.1.1" "--dns=8.8.8.8" ];
    volumes = [
      "${data}:/data"
      "/var/lib/minecraft-modpacks:/modpacks:ro"
    ];
    environmentFiles = [ "${data}/rcon.env" modpackEnv ];
    environment = {
      EULA = "TRUE";
      # must fit the balloon floor
      MEMORY = "6G";
      DIFFICULTY = "hard";
      ICON = "https://d.furaffinity.net/art/skullfugg/1697237475/1697237475.skullfugg_boykisser_ych_mdp_alt_for_frostywuff__1.png";
      OVERRIDE_ICON = "TRUE";
      MOTD = "nya~ minecwaft sewvew 🐾✨";
      VIEW_DISTANCE = "16";
      SPAWN_PROTECTION = "0";
      MAX_PLAYERS = "42069";
      ENABLE_RCON = "true";
      ENABLE_WHITELIST = "true";
      ENFORCE_WHITELIST = "true";
      OPS = "apokryphos";
      WHITELIST = builtins.concatStringsSep "," [
        "apokryphos"
        "zidoio"
      ];
      # drop the previous pack's mods
      REMOVE_OLD_MODS = "TRUE";
      # the vm idles out instead
      MAX_TICK_TIME = "-1";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${data} 0750 1000 1000 -"
    "d /var/lib/minecraft-modpacks 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 25565 25575 ];
}
