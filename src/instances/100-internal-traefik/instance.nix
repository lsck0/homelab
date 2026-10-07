# internal reverse proxy: tls, forwardauth, on-demand wake
{ ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "containers" ];
    memoryMiB = 1024;
    # every internal route and sso: never ballooned below what it runs in (the 512 MiB floor thrashed it to a halt)
    balloonMiB = 1024;
  };

  secrets = {
    proxmox-wake-token-internal = "manual"; # init.sh: the on-demand token, powers the internal zone's onDemand guests only
  };
}
