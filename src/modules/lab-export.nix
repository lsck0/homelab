# the interface for desktop clients: what a workstation's tools need to know about the lab, one json, no nix
#
# sync.sh writes it to src/generated/lab.json on every run (`nix eval --json .#lab.export`); the owner's dotfiles read
# that file (the bar's homelab widget, the ntfy notifier) instead of parsing nix. It holds addresses, names and urls,
# nothing secret: the repo is public. `schema` changes only when a key changes meaning or goes away; a new key is no
# new schema.
#
#   schema       1
#   domain       the lab's domain
#   zones        <zone> -> { subnet; router; ingress; }  the router's address in the zone, the ingress's vmid or null
#   guests       <vmid> -> { name; zone; ip; enabled; }  name <vmid>-<zone>-<service> (the router: its hostname),
#                zone also "router", enabled "true" | "false" | "onDemand"
#   routes       <route> -> { host; path; zone; protocol; vmid; app; port; health; }  host the fqdn, zone internal or
#                external, vmid (an instance's) or app (a swarm app's), port the backend's, health null for none
#   infra        [{ name; href; ping; }]  the lab's frame (modules/infra.nix) in display order, null where none
#   proxmox      { ip; url; }  the hypervisor and its web ui
#   monitoring   { prometheus; loki; grafana; dashboard; accessLog; }  the query apis, grafana's url, the overview
#                board's path on it, the promtail `host` of the public ingress's access log
#   ntfy         { url; topics; desktop; }  the server, its topics by role, the topics the desktop token reads
{ lib, lab }:
let
  inherit (lab) inventory site;
  net = import ./net.nix { inherit lib inventory site; };
  telemetry = import ./telemetry.nix { inherit lib inventory; };
  infra = import ./infra.nix { inherit net; };
  ntfy = import ./ntfy.nix;

  # the catalog every host sees (modules/apps-catalog), evaluated alone: the apps' routes with their ports resolved
  catalog = (lib.evalModules {
    modules = [
      ./apps-catalog
      {
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
        config._module.args = { inherit inventory site lab; };
      }
    ];
  })._module.args.catalog;

  urlOf = host: "https://${net.fqdn host}";
  routeOf = r: {
    host = net.fqdn r.host;
    inherit (r) path zone protocol vmid app port health;
  };
in
assert lib.assertMsg (catalog.problems == [ ]) "lab.export: the app catalog breaks its rules:\n${lib.concatLines catalog.problems}";
{
  schema = 1;
  inherit (site) domain;

  zones = lib.mapAttrs (_: z: {
    inherit (z) subnet;
    router = z.routerIp;
    ingress = if z.ingress == null then null else lib.toInt z.ingress;
  }) net.zones;

  guests = lib.mapAttrs (_: g: {
    inherit (g) name ip enabled;
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
}
