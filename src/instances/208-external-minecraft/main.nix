# Minecraft behind lazymc: lazymc owns the public port and answers status pings itself, so internet port scans never
# start the server (a generic tcp wake proxy would stay awake forever); it boots the container on a real player login
# and stops it with rcon `stop`, which frees the jvm heap, after sleepAfterS without players.
# Who may join and who is op lives in whitelist.json and ops.json in the nas data dir (`mc-rcon whitelist add`,
# `mc-rcon op`), not in this public repo.
{ config, lib, pkgs, nasMount, inventory, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };

  data = "/var/lib/minecraft";
  modpacksDir = "/var/lib/minecraft-modpacks";
  modpackEnv = "${data}/modpack.env";
  # the server's secrets and lazymc's config, rendered by sops under /run: never on the nas, never in a snapshot
  serverEnv = config.sops.templates."minecraft-server.env".path;
  lazymcToml = config.sops.templates."lazymc.toml".path;
  image = "itzg/minecraft-server:2026.9.1-java25";
  container = "minecraft";
  # the image's uid and gid
  serverUid = "1000";

  publicPort = net.ports.minecraft;
  # the container's game port, published on loopback for lazymc only
  serverPort = 25566;
  rconPort = 25575;
  # instance.nix gives the guest 8 GiB unballooned: the heap plus 2 GiB for the os and the jvm's off-heap
  heapSize = "6G";
  # a short break keeps the world warm, an evening off frees the heap
  sleepAfterS = 1800;
  minimumOnlineS = 60;
  containerDns = [ "1.1.1.1" "8.8.8.8" ];

  defaultModpack = ''
    TYPE=VANILLA
    VERSION=LATEST
    LEVEL=vanilla
  '';

  # lazymc runs this and manages it as its child: its rcon stop or signal ends the server and --rm reaps the container
  mcStart = pkgs.writeShellScript "mc-start" ''
    set -euo pipefail
    ${pkgs.podman}/bin/podman rm --force --ignore ${container}
    exec ${pkgs.podman}/bin/podman run --rm --name ${container} \
      ${lib.concatMapStringsSep " " (ip: "--dns=${ip}") containerDns} \
      -p 127.0.0.1:${toString serverPort}:${toString publicPort} -p 127.0.0.1:${toString rconPort}:${toString rconPort} \
      -v ${data}:/data -v ${modpacksDir}:/modpacks:ro \
      --env-file ${serverEnv} --env-file ${modpackEnv} \
      -e EULA=TRUE \
      -e MEMORY=${heapSize} \
      -e DIFFICULTY=hard \
      -e ICON=https://d.furaffinity.net/art/skullfugg/1697237475/1697237475.skullfugg_boykisser_ych_mdp_alt_for_frostywuff__1.png \
      -e OVERRIDE_ICON=TRUE \
      -e "MOTD=nya~ minecwaft sewvew 🐾✨" \
      -e VIEW_DISTANCE=16 \
      -e SPAWN_PROTECTION=0 \
      -e MAX_PLAYERS=42069 \
      -e ENABLE_RCON=true \
      -e ENABLE_WHITELIST=true \
      -e ENFORCE_WHITELIST=true \
      -e REMOVE_OLD_MODS=TRUE \
      -e MAX_TICK_TIME=-1 \
      ${image}
  '';

  # the default pack on a fresh data dir; mc-modpack replaces it
  mcModpackDefault = pkgs.writeShellScript "minecraft-modpack-default" ''
    [ -s ${modpackEnv} ] || printf '%s' ${lib.escapeShellArg defaultModpack} > ${modpackEnv}
  '';

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
      vanilla) env="TYPE=VANILLA" ;;
      # most curseforge packs need the minecraft-cf-api-key secret
      *curseforge.com*) env=$(printf 'TYPE=AUTO_CURSEFORGE\nCF_PAGE_URL=%s' "$arg") ;;
      *) env=$(printf 'TYPE=MODRINTH\nMODRINTH_MODPACK=%s' "$arg") ;;
    esac
    printf '%s\nVERSION=%s\nLEVEL=%s\n' "$env" "$version" "$slug" > ${modpackEnv}.tmp
    mv ${modpackEnv}.tmp ${modpackEnv}
    systemctl restart lazymc
    echo "modpack set to $arg (world: $slug); the next join boots it, the first start downloads the pack"
  '';

  # only works while a player has the server awake
  mcRcon = pkgs.writeShellScriptBin "mc-rcon" ''
    exec ${pkgs.podman}/bin/podman exec ${container} rcon-cli "$@"
  '';
in {
  homelab.nasMounts = nasMount data "minecraft" // nasMount modpacksDir "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = { };
  sops.secrets.minecraft-cf-api-key = { };
  sops.templates."minecraft-server.env" = {
    content = ''
      RCON_PASSWORD=${config.sops.placeholder.minecraft-rcon-password}
      CF_API_KEY=${config.sops.placeholder.minecraft-cf-api-key}
    '';
    restartUnits = [ "lazymc.service" ];
  };
  # it embeds mcStart, so a new start command restarts lazymc
  sops.templates."lazymc.toml" = {
    content = ''
      [public]
      address = "0.0.0.0:${toString publicPort}"

      [server]
      address = "127.0.0.1:${toString serverPort}"
      command = "${mcStart}"
      # stop frees the heap, freeze would keep it
      freeze_process = false
      wake_on_start = false

      [rcon]
      enabled = true
      port = ${toString rconPort}
      password = "${config.sops.placeholder.minecraft-rcon-password}"
      # itzg sets the password from the env; lazymc must not rewrite server.properties
      randomize_password = false

      [time]
      sleep_after = ${toString sleepAfterS}
      minimum_online_time = ${toString minimumOnlineS}

      [advanced]
      rewrite_server_properties = false
    '';
    restartUnits = [ "lazymc.service" ];
  };

  # lazymc runs the server as a raw `podman run`, not via oci-containers
  virtualisation.podman.enable = true;

  environment.systemPackages = [ mcModpack mcRcon ];

  systemd.services.lazymc = {
    description = "lazymc: sleep/wake the Minecraft server on real player logins";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # the nfs data dir may lag the boot
    startLimitIntervalSec = 0;
    path = [ pkgs.podman ];
    serviceConfig = {
      ExecStartPre = mcModpackDefault;
      ExecStart = "${pkgs.lazymc}/bin/lazymc start --config ${lazymcToml}";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStopPost = "${pkgs.podman}/bin/podman rm --force --ignore ${container}";
      KillMode = "mixed";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${data} 0750 ${serverUid} ${serverUid} -"
    "d ${modpacksDir} 0750 ${serverUid} ${serverUid} -"
  ];

}
