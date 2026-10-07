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
    off = { homepage = "a game server, no page"; probe = "lazymc answers the protocol, not http"; };
  };

  secrets = { minecraft-rcon-password = "hex:24"; };
}
