# internal reverse proxy: tls, forwardauth, on-demand wake
{ net, ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "containers" ];
    memoryMiB = 1024;
  };

  grants = [
    { from = [ "105" ]; tcp = [ net.ports.traefikMetrics ]; why = "vm-105 scrapes the internal ingress"; }
  ];

  secrets = {
    proxmox-wake-token-internal = "manual"; # init.sh: the on-demand token, powers the internal zone's onDemand guests only
    registry-push-password = "hex:24"; # registry user ci: REGISTRY_PASSWORD of the repos that push images
  };
}
