# both ingresses' memory: traefik, crowdsec and its appsec waf, anubis (100-internal, 200-external instance.nix `vm`)
{
  # crowdsec oom-killed the external one at 1024
  memoryMiB = 1536;
  # 631 MiB peak over 7d on the external one; at a 512 floor the internal one thrashed to a halt
  balloonMiB = 1024;
}
