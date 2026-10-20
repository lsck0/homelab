# internal reverse proxy: tls, forwardauth, on-demand wake
_: {
  on = [ "ingress" ];

  vm = import ../../../modules/traefik/lib/vm.nix // {
    bootPhase = "network";
    needs = [ "containers" ];
    # 631 MiB peak over 35d; crowdsec's oom was the external one's (vm.nix)
    memoryMiB = 1024;
  };

  secrets = {
    proxmox-wake-token-internal = "manual"; # init.nu: the on-demand token, powers the internal zone's onDemand guests only
  };
}
