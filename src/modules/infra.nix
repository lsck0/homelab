# the lab's frame: what holds the lab up but is no route of its own (the house router, proxmox, the lab's router and
# ingresses, outside dashboards), in display order. The homepage's Infra group (103-internal-homepage) shows it with
# widgets; lab.export hands it to the desktop clients.
#
#   infra = import ../modules/infra.nix { inherit net; };
#   infra.cards        # [{ name; icon; href; ping; description; }], null where a card has none
#   infra.fritzbox     # the house router's web ui
#   infra.proxmoxApi   # <address>:<port> of the proxmox api
{ net }:
let
  hostUrl = host: "https://${net.fqdn host}";
  fritzbox = "http://${net.wan.gateway}";
  proxmoxApi = "${net.wan.proxmox}:${toString net.ports.proxmoxApi}";
  cardOf = card: { href = null; ping = null; description = null; } // card;
in {
  inherit fritzbox proxmoxApi;

  cards = map cardOf [
    { name = "Cloudflare"; icon = "cloudflare"; href = "https://dash.cloudflare.com"; }
    { name = "FritzBox"; icon = "mdi-router-wireless"; href = fritzbox; ping = fritzbox; }
    { name = "Proxmox"; icon = "proxmox"; href = hostUrl net.ingressPages.proxmox; ping = "http://${proxmoxApi}"; }
    { name = "Router"; icon = "nixos"; ping = "http://${net.zones.internal.routerIp}"; }
    { name = "Traefik"; icon = "traefik"; href = hostUrl net.ingressPages.dashboard; ping = "http://${net.ipOf net.zones.internal.ingress}";
      description = "Internal ingress"; }
    { name = "Traefik DMZ"; icon = "traefik"; ping = "http://${net.ipOf net.zones.external.ingress}"; description = "Public ingress"; }
    { name = "Terminal"; icon = "mdi-tablet-dashboard"; href = "https://trmnl.com/dashboard"; }
  ];
}
