# the third-party services the lab depends on, each with the url that tells whether it is up: any answer below 500
# is up. modules/upstream wraps every call to one, vm-105 probes each and alerts "<name> unavailable" once per name.
{
  aur.url = "https://aur.archlinux.org/rpc/v5/info";
  archlinux.url = "https://geo.mirror.pkgbuild.com/core/os/x86_64/core.db";
  github.url = "https://api.github.com/zen";
  cloudflare.url = "https://api.cloudflare.com/client/v4/ips";
  letsencrypt.url = "https://acme-v02.api.letsencrypt.org/directory";
  ipify.url = "https://api.ipify.org";
  telegram.url = "https://api.telegram.org";
  anthropic.url = "https://api.anthropic.com";
  proton.url = "https://drive-api.proton.me";
  dockerhub.url = "https://registry-1.docker.io/v2/";
  ghcr.url = "https://ghcr.io/v2/";
  crowdsec.url = "https://hub-data.crowdsec.net";
}
