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
    image = "itzg/minecraft-server:latest";
    ports = [ "25565:25565" "25575:25575" ];
    volumes = [
      "/var/lib/minecraft:/data"
      "/var/lib/minecraft-modpacks:/modpacks:ro"
    ];
    environmentFiles = [ "/var/lib/minecraft/rcon.env" ];
    environment = {
      EULA = "TRUE";
      MEMORY = "11G";
      DIFFICULTY = "hard";
      # Custom server icon — place a 64x64 PNG at /var/lib/minecraft/server-icon.png
      # or set ICON to a URL:
      # ICON = "https://example.com/icon.png";
      OVERRIDE_ICON = "TRUE";
      MOTD = "Homelab Minecraft";
      ENABLE_COMMAND_BLOCK = "true";
      SNOOPER_ENABLED = "false";
      VIEW_DISTANCE = "12";
      MAX_PLAYERS = "10";
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
      TYPE = "VANILLA";
      VERSION = "LATEST";
      #
      # Modrinth modpack:
      #   TYPE = "MODRINTH";
      #   MODRINTH_MODPACK = "https://modrinth.com/modpack/cobblemon-fabric";
      #   VERSION = "LATEST";
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
