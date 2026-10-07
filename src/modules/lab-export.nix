# the interface for desktop clients: what a workstation's tools need to know about the lab, one json, no nix
#
# sync.sh writes it to src/generated/lab.json on every run (`nix eval --json .#lab.export`); the owner's dotfiles read
# that file (the bar's homelab widget, the ntfy notifier) instead of parsing nix. It holds addresses, names and urls,
# nothing secret: the repo is public. `schema` changes only when a key changes meaning or goes away; a new key is no
# new schema.
#
#   schema       1
#   domain       the lab's domain
#   router       the router's address on the house lan
#   zones        <zone> -> { subnet; router; ingress; }  the router's address in the zone, the ingress's vmid or null
#   guests       <vmid> -> { name; zone; ip; powered; idle; enabled; }  name <vmid>-<zone>-<service> (the router: its
#                hostname), zone also "router", powered a bool, idle its stop delay ("30m") or null; enabled the
#                former tri-state "true" | "false" | "onDemand", kept until the desktop clients read powered and idle
#   routes       <route> -> { host; path; zone; protocol; vmid; app; port; health; }  host the fqdn, zone internal or
#                external, vmid (an instance's) or app (a swarm app's), port the backend's, health null for none
#   infra        [{ name; href; ping; }]  the lab's frame (modules/infra.nix) in display order, null where none
#   proxmox      { ip; url; }  the hypervisor and its web ui
#   monitoring   { prometheus; loki; grafana; dashboard; accessLog; }  the query apis, grafana's url, the overview
#                board's path on it, the promtail `host` of the public ingress's access log
#   ntfy         { url; topics; desktop; }  the server, its topics by role, the topics the desktop token reads
#   ldap         { baseDn; adminGroup; vmid; host; port; }  the directory the proxmox realm binds to over ldaps, and
#                the guest serving it
{ lib, lab }:
let
  inherit (lab) inventory site catalog;
  net = import ./net.nix { inherit lib inventory site; };
  telemetry = import ./telemetry.nix { inherit lib inventory; };
  infra = import ./infra.nix { inherit net; };
  ntfy = import ./ntfy.nix;

  urlOf = host: "https://${net.fqdn host}";
  routeOf = r: {
    host = net.fqdn r.host;
    inherit (r) path zone protocol vmid app port health;
  };
in
{
  schema = 1;
  inherit (site) domain;
  inherit (site.lan) router;

  zones = lib.mapAttrs (_: z: {
    inherit (z) subnet;
    router = z.routerIp;
    ingress = if z.ingress == null then null else lib.toInt z.ingress;
  }) net.zones;

  guests = lib.mapAttrs (_: g: {
    inherit (g) name ip powered idle enabled;
    zone = g.type;
  }) inventory;

  routes = lib.mapAttrs (_: routeOf) (catalog.internal // catalog.external // catalog.l4);

  infra = map (c: { inherit (c) name href ping; }) infra.cards;

  proxmox = {
    ip = site.lan.proxmox;
    url = urlOf net.ingressPages.proxmox;
  };

  monitoring = {
    inherit (telemetry.urls) prometheus loki;
    grafana = urlOf catalog.internal.grafana.host;
    dashboard = "/d/${telemetry.homelabDashboardUid}";
    accessLog = "vm-${net.zones.external.ingress}";
  };

  ntfy = {
    url = urlOf catalog.external.ntfy.host;
    inherit (ntfy) topics;
    desktop = ntfy.desktopTopics;
  };

  ldap = {
    baseDn = net.domainDn;
    adminGroup = catalog.access.admins;
    vmid = catalog.internal.lldap.vmid;
    host = inventory.${toString catalog.internal.lldap.vmid}.ip;
    port = net.ports.ldaps;
  };
}
