# Minecraft servers; mc-gate sleeps and wakes one of them per real player login
{ config, profiles, ... }: {
  vm = {
    bootPhase = "public";
    needs = [ "containers" "nfs" ];
    # no ballooning: the jvm's growing heap (main.nix heapSize) in a ballooned-down guest gets oom-killed
    memoryMiB = 10240;
    balloonMiB = 10240;
    # the tick is one thread, but chunk generation, distant horizons and g1 run beside it: 6 ran at load 6.7 with
    # 20 s stalls exploring; the host has 12 threads, most guests idle, and this one wins when they are not
    cores = 10;
    cpuUnits = 200;
    diskGiB = 16;
  };

  services.minecraft = {
    # one name per server, <server>.mc.lsck0.dev; the gate reads the name the player dialed, so there is no srv
    # record: an srv target would be the address every client sends instead
    host = "*.mc";
    protocol = "tcp";
    # the protocol's default: every client dials it
    port = 25565;
    publicPort = config.services.minecraft.port;
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
