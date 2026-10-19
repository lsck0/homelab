# Minecraft servers; mc-gate sleeps and wakes one of them per real player login
{ config, profiles, ... }:
{
  vm = {
    bootPhase = "public";
    needs = [
      "containers"
      "nfs"
    ];
    # never ballooned: a squeezed jvm is killed by the kernel and loses the unsaved world (it did at 6.1 GiB)
    memoryMiB = 8192;
    balloonMiB = 0;
    # the tick is one thread, but chunk generation, distant horizons and g1 run beside it: 6 ran at load 6.7 with
    # 20 s stalls exploring; the host has 12 threads, most guests idle, and this one wins when they are not
    cores = 10;
    # a world generating flat out still leaves the host 4 of its 12 threads
    cpuLimitCores = 8;
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
    on = [
      "inflightLimit"
      "accessLog"
      "probe"
    ]
    ++ profiles.observed;
  };

  alerts =
    let
      # one failed start is a slow first download or a pack being swapped; the comparison is strict, so the second
      # failure within an hour crosses this and is the pack, the world or the disk
      startFailuresHourly = 1;
    in
    {
      minecraft_start_failed = {
        title = "Minecraft server did not start";
        category = "service";
        # mc-gate counts a start it issued that never came up: systemd refused it, the unit failed, or it timed out
        expr = "max by (server) (increase(homelab_mc_start_failures_total[1h]))";
        threshold = startFailuresHourly;
        for = "0m";
        summary = "{{ $labels.server }} did not start: {{ $values.A.Value | printf \"%.0f\" }} failures in the last hour";
        description = "Players wake the server by joining and it never comes up. `mc-state` and `journalctl -u minecraft-{{ $labels.server }} -u mc-gate` on vm-214; a pack that was just changed downloads on its first start and may simply be slow.";
      };
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
