# Minecraft server; lazymc sleeps/wakes the server per real player logins
{ net, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
    # no ballooning: the jvm's growing heap (main.nix heapSize) in a ballooned-down guest gets oom-killed
    power = "off";
    memoryMiB = 8192;
    balloonMiB = 8192;
    cores = 4;
    diskGiB = 16;
  };

  services.minecraft = {
    host = "mc";
    protocol = "tcp";
    port = net.ports.minecraft;
    publicPort = net.ports.minecraft;
    srv = "_minecraft._tcp";
    off = { homepage = "a game server, no page"; };
  };

  shares = {
    "data/minecraft" = { };
    "data/minecraft-modpacks" = { };
  };

  secrets = {
    minecraft-rcon-password = "hex:24";
    minecraft-cf-api-key = "manual"; # console.curseforge.com, for curseforge modpacks; empty is fine without them
  };
}
