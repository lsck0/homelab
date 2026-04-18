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
      MEMORY = "2G";
      DIFFICULTY = "normal";
      OPS = "";
      MOTD = "Homelab Minecraft";
    };
  };

  networking.firewall.allowedTCPPorts = [ 25565 ];
}
