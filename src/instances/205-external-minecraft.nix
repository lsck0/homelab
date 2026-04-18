{ config, nasMount, ... }: {
  networking.hostName = "vm-205";

  fileSystems = nasMount "/var/lib/minecraft" "minecraft"
    // nasMount "/var/lib/minecraft-modpacks" "minecraft-modpacks";

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:latest";
    ports = [ "25565:25565" "25575:25575" ];
    volumes = [
      "/var/lib/minecraft:/data"
      "/var/lib/minecraft-modpacks:/modpacks:ro"
    ];
    environment = {
      EULA = "TRUE";
      TYPE = "FORGE";
      VERSION = "1.20.1";
      MEMORY = "3G";
      DIFFICULTY = "normal";
      MOTD = "Homelab Minecraft";
      ENABLE_COMMAND_BLOCK = "true";
      SNOOPER_ENABLED = "false";
      VIEW_DISTANCE = "12";
      MAX_PLAYERS = "10";
      ENABLE_RCON = "true";
      RCON_PASSWORD = "changeme";
      ENABLE_WHITELIST = "true";
      ENFORCE_WHITELIST = "true";

      # ── modpack options (uncomment one) ──
      #
      # server zip (auto-extracted):
      #   GENERIC_PACK = "/modpacks/server-pack.zip";
      #
      # curseforge page:
      #   TYPE = "AUTO_CURSEFORGE";
      #   CF_PAGE_URL = "https://www.curseforge.com/minecraft/modpacks/...";
      #   CF_API_KEY = "...";
      #
      # pack with its own run script (bypasses itzg launcher):
      #   TYPE = "CUSTOM";
      #   CUSTOM_SERVER = "/data/forge-server.jar";
      #   or extract pack to /var/lib/minecraft/ and:
      #   SKIP_SERVER_PROPERTIES = "true";
      #   EXEC_DIRECTLY = "true";
      #   CUSTOM_SERVER = "/data/run.sh";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft 0750 1000 1000 -"
    "d /var/lib/minecraft-modpacks 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
