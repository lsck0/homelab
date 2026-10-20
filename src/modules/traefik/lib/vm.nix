# both ingresses' memory: traefik, crowdsec and its appsec waf, anubis (100-internal, 200-external instance.nix `vm`)
{
  # crowdsec oom-killed the external one at 1024; 812 MiB peak over 35d on the external one
  memoryMiB = 1280;
}
