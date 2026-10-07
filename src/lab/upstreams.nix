# third-party services the lab depends on -> the url whose answer below 500 means up (modules/upstream)
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
  # image registries also name the host an image reference starts with (modules/upstream registries)
  dockerhub = { url = "https://registry-1.docker.io/v2/"; registry = "docker.io"; };
  ghcr = { url = "https://ghcr.io/v2/"; registry = "ghcr.io"; };
  quay = { url = "https://quay.io/v2/"; registry = "quay.io"; };
  crowdsec.url = "https://hub-data.crowdsec.net";
}
