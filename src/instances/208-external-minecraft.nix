{ config, pkgs, nasMount, ... }:
let
  data = "/var/lib/minecraft";
  # runtime server type/modpack
  modpackEnv = "${data}/modpack.env";
  lazymcToml = "${data}/lazymc.toml";
  image = "itzg/minecraft-server:2026.9.1-java25";
  defaultModpack = ''
    TYPE=VANILLA
    VERSION=LATEST
    LEVEL=vanilla
  '';

  # lazymc owns the server: it answers status pings itself (so internet port scans
  # never start it), boots the container only on a real player login, and stops it
  # (rcon `stop`, which frees the jvm heap) after the idle timeout. this replaces the
  # generic tcp wake proxy, which a scanned public port keeps awake forever.
  sleepAfter = 1800; # 30m, matches the old onDemand cooldown

  # lazymc runs this to start the server; it becomes the managed child, so lazymc's
  # rcon stop / signal cleanly ends it and podman --rm reaps the container.
  mcStart = pkgs.writeShellScript "mc-start" ''
    set -euo pipefail
    ${pkgs.podman}/bin/podman rm -f minecraft 2>/dev/null || true
    exec ${pkgs.podman}/bin/podman run --rm --name minecraft \
      --dns=1.1.1.1 --dns=8.8.8.8 \
      -p 127.0.0.1:25566:25565 -p 127.0.0.1:25575:25575 \
      -v ${data}:/data -v /var/lib/minecraft-modpacks:/modpacks:ro \
      --env-file ${data}/rcon.env --env-file ${modpackEnv} \
      -e EULA=TRUE \
      -e MEMORY=6G \
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
      -e OPS=apokryphos \
      -e WHITELIST=apokryphos,zidoio \
      -e REMOVE_OLD_MODS=TRUE \
      -e MAX_TICK_TIME=-1 \
      ${image}
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
    echo ">>> modpack set to $arg (world: $slug); restart the server for it to take effect."
    echo ">>> lazymc starts it on the next join (first start downloads the pack), or force now:"
    echo ">>>   systemctl restart lazymc && mc-rcon list  # the second boots it"
    systemctl restart lazymc
  '';

  # mc-rcon <command...>: only works while a player has the server awake
  mcRcon = pkgs.writeShellScriptBin "mc-rcon" ''
    exec ${pkgs.podman}/bin/podman exec minecraft rcon-cli "$@"
  '';
in {
  networking.hostName = "vm-208";

  fileSystems = nasMount data "minecraft"
    // nasMount "/var/lib/minecraft-modpacks" "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = {};

  # lazymc runs the server as a raw `podman run`, not via oci-containers, so enable podman explicitly
  virtualisation.podman.enable = true;

  environment.systemPackages = [ mcModpack mcRcon ];

  systemd.services.minecraft-env = {
    description = "Generate Minecraft env + lazymc config";
    before = [ "lazymc.service" ];
    requiredBy = [ "lazymc.service" ];
    # regenerate the toml (and re-run) whenever the start command changes, else a deploy
    # leaves lazymc pointing at a stale mc-start (old memory/env)
    restartTriggers = [ mcStart ];
    serviceConfig.Type = "oneshot";
    script = ''
      pw=$(cat ${config.sops.secrets.minecraft-rcon-password.path})
      echo "RCON_PASSWORD=$pw" > ${data}/rcon.env
      chmod 600 ${data}/rcon.env
      [ -s ${modpackEnv} ] || printf '%s' ${pkgs.lib.escapeShellArg defaultModpack} > ${modpackEnv}

      # lazymc: public port fronts the game, connects to the container's game+rcon on localhost
      umask 077
      cat > ${lazymcToml} <<EOF
      [public]
      address = "0.0.0.0:25565"

      [server]
      address = "127.0.0.1:25566"
      command = "${mcStart}"
      # stop (free the heap), do not freeze (which keeps ram)
      freeze_process = false
      wake_on_start = false

      [rcon]
      enabled = true
      port = 25575
      password = "$pw"
      # use itzg's env-set password, do not randomize or rewrite server.properties
      randomize_password = false

      [time]
      sleep_after = ${toString sleepAfter}
      minimum_online_time = 60

      [advanced]
      rewrite_server_properties = false
      EOF
    '';
  };

  systemd.services.lazymc = {
    description = "lazymc: sleep/wake the Minecraft server on real player logins";
    after = [ "network-online.target" "minecraft-env.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    # restart with a new start command so the deployed memory/env actually takes effect
    restartTriggers = [ mcStart ];
    path = [ pkgs.podman ];
    serviceConfig = {
      ExecStart = "${pkgs.lazymc}/bin/lazymc start --config ${lazymcToml}";
      Restart = "on-failure";
      RestartSec = 5;
      # lazymc spawns the container; on stop it must reap it too
      ExecStopPost = "${pkgs.podman}/bin/podman rm -f minecraft";
      KillMode = "mixed";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${data} 0750 1000 1000 -"
    "d /var/lib/minecraft-modpacks 0750 1000 1000 -"
  ];

  # 25565 = lazymc (public game port); rcon 25575 stays on localhost only
  networking.firewall.allowedTCPPorts = [ 25565 ];
}
