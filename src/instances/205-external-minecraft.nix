{ ... }: {
  networking.hostName = "vm-205";

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:latest";
    ports = [ "25565:25565" ];
    volumes = [
      "/var/lib/minecraft:/data"
      # to install a modpack, place the server zip at /var/lib/minecraft-modpacks/
      # and set GENERIC_PACK below to the filename
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
      # for custom modpacks: set TYPE=AUTO_CURSEFORGE and CF_PAGE_URL
      # or set GENERIC_PACK=/modpacks/server-pack.zip
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft 0750 1000 1000 -"
    "d /var/lib/minecraft-modpacks 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
