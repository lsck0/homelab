# public reverse proxy: tls, crowdsec, anubis, waf
{ id, net, ... }: {
  vm = import ../../modules/traefik/lib/vm.nix // {
    bootPhase = "network";
    needs = [ "containers" ];
  };

  alerts.attack_flood = {
    title = "Traffic flood";
    category = "attack";
    # crowdsec blocks tens of scans an hour; only a sustained flood orders of magnitude above that wakes anyone
    expr = "sum(rate(traefik_entrypoint_requests_total{entrypoint=\"websecure\",instance=\"${net.ipOf id}:${toString net.ports.traefikMetrics}\"}[5m]))";
    threshold = 50;
    for = "15m";
    telegram = true;
    summary = "{{ $values.A.Value | printf \"%.0f\" }} req/s sustained 15m: possible DoS";
    description = "Requests are far above baseline for 15 minutes. CrowdSec blocks known-bad; check `cscli metrics` and top talkers on vm-${id}. Routine scans do not trigger this.";
  };

  secrets = {
    anubis-ed25519-key = "hex:32"; # ed25519 seed as hex, the form anubis reads
    proxmox-wake-token-external = "manual"; # init.sh: the on-demand token, powers the dmz's onDemand guests only
  };
}
