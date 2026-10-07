# the internal ingress: every internal route (modules/catalog.nix) with its protection (modules/traefik), the
# on-demand wake of the internal zone's sleeping guests, and the relay target of the edge
{ config, lib, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  authelia = catalog.internal.authelia;
in {
  # backends wake via homelab.onDemand, with the internal zone's token (granted on that zone's sleepers only)
  homelab.onDemand = {
    enable = true;
    side = "internal";
  };

  homelab.traefik = {
    enable = true;
    routes = catalog.internal;

    # the edge relays to this ingress, and the chains it relays carry cloudflare's hop
    trustedProxies = [ (net.hostSource net.zones.external.ingress) ];
    trustCloudflare = true;

    authelia.address = "http://${net.ipOf (toString authelia.vmid)}:${toString authelia.port}/api/authz/forward-auth";

    # the edge's defence here too, for lan clients and relayed ones alike; never ban the house or the lab
    crowdsecBouncer = { enable = true; whitelistCidrs = net.privateRanges; };
    # robots.txt, llms.txt and the labyrinth, as on the edge
    botDefense.enable = true;

    # the apps zone is a dmz: only a route admitting it by its sources (the registry's pulls) answers it
    refusedClients = [ net.zones.apps.subnet ];

    loopbackPorts = lib.mapAttrs' (name: svc: lib.nameValuePair "ondemand-${name}" svc.listenPort) config.homelab.onDemand.services;

    # this ingress's own pages, behind authelia
    routers = {
      traefik-dash-tls = {
        rule = "Host(`${net.fqdn net.ingressPages.dashboard}`)";
        service = "api@internal";
        entryPoints = [ "websecure" ];
        middlewares = [ "authelia" ];
        # traefik 3.6.10 panics behind the buffering middleware ("invalid WriteHeader code 0", the page never loads)
        off.bodyLimit = "api@internal takes no uploads, and the body limit breaks its dashboard";
      };
      proxmox-tls = {
        rule = "Host(`${net.fqdn net.ingressPages.proxmox}`)";
        service = "proxmox";
        entryPoints = [ "websecure" ];
        middlewares = [ "authelia" ];
        off.bodyLimit = "iso and disk uploads through the web ui";
      };
    };
    services.proxmox.loadBalancer = {
      servers = [{ url = "https://${net.wan.proxmox}:${toString net.ports.proxmoxApi}"; }];
      serversTransport = "proxmox";
    };
    # proxmox's own certificate, issued by its root ca for the host's address
    serversTransports.proxmox.rootCAs = [ config.sops.secrets.proxmox-ca.path ];
  };

  sops.secrets.proxmox-ca.owner = "traefik";
}
