# public reverse proxy: tls, crowdsec, anubis, waf
{ ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "containers" ];
    # crowdsec oom-killed at 1024; 631 MiB peak over 7d
    memoryMiB = 1536;
    balloonMiB = 1024;
  };

  secrets = {
    anubis-ed25519-key = "hex:32"; # ed25519 seed as hex, the form anubis reads
    proxmox-wake-token-external = "manual"; # init.sh: the on-demand token, powers the dmz's onDemand guests only
  };
}
