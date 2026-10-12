# Minecraft server; lazymc sleeps/wakes the server per real player logins
{ config, profiles, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
    # no ballooning: the jvm's growing heap (main.nix heapSize) in a ballooned-down guest gets oom-killed
    memoryMiB = 10240;
    balloonMiB = 10240;
    cores = 6;
    diskGiB = 16;
  };

  services.minecraft = {
    host = "mc";
    protocol = "tcp";
    # the protocol's default: clients without the srv record dial it
    port = 25565;
    publicPort = config.services.minecraft.port;
    srv = "_minecraft._tcp";
    # the router caps and logs its forward; a game server, no page
    on = [ "inflightLimit" "accessLog" "probe" ] ++ profiles.observed;
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
