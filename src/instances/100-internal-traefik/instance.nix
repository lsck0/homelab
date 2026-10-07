# internal reverse proxy: tls, forwardauth, on-demand wake
{ ... }: {
  vm = import ../../modules/traefik/lib/vm.nix // {
    bootPhase = "network";
    needs = [ "containers" ];
  };

  secrets = {
    proxmox-wake-token-internal = "manual"; # init.sh: the on-demand token, powers the internal zone's onDemand guests only
  };
}
