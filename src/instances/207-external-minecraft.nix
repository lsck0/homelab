{ config, nasMount, ... }: {
  networking.hostName = "vm-207";

  fileSystems = nasMount "/var/lib/minecraft" "minecraft"
    // nasMount "/var/lib/minecraft-modpacks" "minecraft-modpacks";

  sops.secrets.minecraft-rcon-password = {};

  # Build env file with RCON password from sops
  systemd.services.minecraft-env = {
    description = "Generate Minecraft env from secrets";
    before = [ "podman-minecraft.service" ];
    requiredBy = [ "podman-minecraft.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      echo "RCON_PASSWORD=$(cat ${config.sops.secrets.minecraft-rcon-password.path})" > /var/lib/minecraft/rcon.env
      chmod 600 /var/lib/minecraft/rcon.env
    '';
  };

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:java21";
    ports = [ "25565:25565" "25575:25575" ];
    volumes = [
      "/var/lib/minecraft:/data"
      "/var/lib/minecraft-modpacks:/modpacks:ro"
    ];
    environmentFiles = [ "/var/lib/minecraft/rcon.env" ];
    environment = {
      EULA = "TRUE";
      MEMORY = "18G";
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
      WHITELIST = builtins.concatStringsSep "," [
        "apokryphos"
      ];

      # ── Server type ──────────────────────────────────────────
      # Default: vanilla. Uncomment ONE block below to switch.
      #
      # Vanilla (default):
      # TYPE = "VANILLA";
      # VERSION = "LATEST";
      #
      # Modrinth modpack:
      TYPE = "MODRINTH";
      MODRINTH_MODPACK = "https://modrinth.com/modpack/cobblemon-fabric";
      VERSION = "LATEST";
      #
      # CurseForge server ZIP (no API key needed):
      #   TYPE = "AUTO_CURSEFORGE";
      #   CF_PAGE_URL = "https://www.curseforge.com/minecraft/modpacks/...";
      #   or local zip:
      #   GENERIC_PACK = "/modpacks/server-pack.zip";
      #
      # Forge:
      #   TYPE = "FORGE";
      #   VERSION = "1.20.1";

      # ── Auto-pause (native, 1.21.2+) ────────────────────────
      # Pauses server tick when no players connected for 24 hours
      PAUSE_WHEN_EMPTY_SECONDS = "86400";
      MAX_TICK_TIME = "-1";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft 0750 1000 1000 -"
    "d /var/lib/minecraft-modpacks 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
