# prowlarr: indexer manager, indexer traffic through tor, flaresolverr beside it
{ config, pkgs, inventory, catalog, hostIp, retry, setupUnit, site, ... }:
let
  route = catalog.internal.prowlarr;
  # the router's tor socks port isolated per destination, at the router's address in this guest's zone
  torSocksIsolatedPort = (import ../../../modules/tor-ports.nix).socksIsolated;
  torHost = inventory."130".gateway;
  # podman's default bridge gateway: prowlarr's container reaches flaresolverr's published port there
  podmanBridgeGateway = "10.88.0.1";
  flaresolverrPort = 8191;
  # flaresolverr renders hostile tracker pages in chromium: its own network, outside the default bridge the guard
  # trusts (modules/network.nix), so a compromised chromium cannot call the arrs' login-free ports
  flaresolverrNetwork = { name = "flaresolverr"; subnet = "10.89.130.0/24"; };
in {
  homelab.servarr.prowlarr.image = "lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161";

  # indexer traffic leaves through tor
  systemd.services.prowlarr-tor-proxy = setupUnit {
    description = "Send Prowlarr's indexer traffic through Tor";
    # setup exports the key read below
    after = [ "podman-prowlarr.service" "prowlarr-setup.service" ];
    wants = [ "prowlarr-setup.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.systemd ];
    serviceConfig.PrivateTmp = true;
    script = ''
      API=http://127.0.0.1:${toString route.port}/api/v1
      # the key in a header file, not on argv
      key=$(token_read prowlarr-key)
      printf 'X-Api-Key: %s\n' "$key" > /tmp/key.header
      ${retry} 60 2 curl -fsS -H @/tmp/key.header "$API/config/host" -o /tmp/host.json

      # allowedHosts in the same write or prowlarr refuses
      jq -c '.
        | .allowedHosts = "${route.host}.${site.domain},${hostIp},127.0.0.1,localhost"
        | .proxyEnabled = true
        | .proxyType = "socks5"
        | .proxyHostname = "${torHost}"
        | .proxyPort = ${toString torSocksIsolatedPort}
        | .proxyUsername = ""
        | .proxyPassword = ""
        | .proxyBypassLocalAddresses = true
        | .proxyBypassFilter = ""' /tmp/host.json > /tmp/host.new

      if jq -e --slurpfile a /tmp/host.json --slurpfile b /tmp/host.new -n '$a[0] == $b[0]' >/dev/null; then
        echo "Prowlarr already proxied through Tor"
        exit 0
      fi

      curl -fsS -X PUT "$API/config/host/$(jq -r .id /tmp/host.json)" -H @/tmp/key.header \
        -H "Content-Type: application/json" --data-binary @/tmp/host.new -o /dev/null
      # kestrel reads allowedHosts only at start
      systemctl restart podman-prowlarr.service
      echo "Prowlarr now reaches indexers through Tor (${torHost}:${toString torSocksIsolatedPort})"
    '';
  };

  systemd.services.podman-network-flaresolverr = {
    description = "Podman network for flaresolverr";
    requiredBy = [ "podman-flaresolverr.service" ];
    before = [ "podman-flaresolverr.service" ];
    path = [ config.virtualisation.podman.package ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      podman network exists ${flaresolverrNetwork.name} \
        || podman network create --subnet=${flaresolverrNetwork.subnet} ${flaresolverrNetwork.name}
    '';
  };

  # flaresolverr for cloudflare-guarded trackers
  virtualisation.oci-containers.containers.flaresolverr = {
    image = "ghcr.io/flaresolverr/flaresolverr:v3.4.2";
    networks = [ flaresolverrNetwork.name ];
    ports = [ "${podmanBridgeGateway}:${toString flaresolverrPort}:${toString flaresolverrPort}" ];
    environment = {
      LOG_LEVEL = "warning";
      TZ = site.timeZone;
    };
    # one chromium per solve
    extraOptions = [ "--memory=1g" ];
  };
  # the default bridge, and its gateway address, exist once podman created them for prowlarr
  systemd.services.podman-flaresolverr = {
    after = [ "podman-prowlarr.service" ];
    wants = [ "podman-prowlarr.service" ];
  };
}
