{ ... }: {
  networking.hostName = "vm-204";

  virtualisation.oci-containers.containers.minecraft = {
    image = "itzg/minecraft-server:latest";
    ports = [ "25565:25565" ];
    volumes = [ "/var/lib/minecraft:/data" ];
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
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/minecraft 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
