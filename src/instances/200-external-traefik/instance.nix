# public reverse proxy: tls, crowdsec, anubis, waf
{ net, ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "containers" ];
    # crowdsec oom-killed at 1024; 631 MiB peak over 7d
    memoryMiB = 1536;
    balloonMiB = 1024;
  };

  grants = [
    { from = [ "105" ]; tcp = [ net.ports.traefikMetrics ]; why = "vm-105 scrapes the edge"; }
  ];

  secrets = {
    anubis-ed25519-key = "hex:32"; # ed25519 seed as hex, the form anubis reads
    proxmox-wake-token-external = "manual"; # init.sh: the on-demand token, powers the dmz's onDemand guests only
  };
}
