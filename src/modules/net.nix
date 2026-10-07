# the lab's network facts, defined once: zones, addresses, well-known ports and the outside ranges it trusts
#
# zones: src/generated/zones.json, which terraform reads too (main.tf), so a zone's bridge, subnet, router leg, ingress and
# dhcp pool are one edit for both. A guest's address is host <id> of its zone's subnet (modules/lab), the router
# is host 1 of every zone, and the router's leg of a zone is proxmox nic `router_nic` (net0 is the wan); modules/lab
# `problems` holds zones.json to these rules.
#
#   net = import ../modules/net.nix { inherit lib inventory site; };
#   net.zones.internal.subnet        # "10.100.0.0/24"
#   net.zones.external.interface     # "ens20", the router's nic in the zone
#   net.ipOf "105"                   # "10.100.0.105"
#   net.hostSource "200"             # "10.200.0.200/32"
#   net.ports.nfs                    # 2049
#
# Everything here is a constant or derived from the inventory and site.json; nothing reads a host's config, so any
# module, the router and the policy laws (tests/policy/network.nix) can import it without a cycle.
{ lib, inventory, site }:
let
  # -------------------------------------------------------------------------------------------------------------
  # CONSTANTS
  # -------------------------------------------------------------------------------------------------------------

  inherit (site) domain;

  # proxmox gives virtio nic netN pci slot 18 + N, which predictable naming calls ens<slot>
  nicPciSlotFirst = 18;
  # the router takes host 1 of every zone; guest ids start at 100, so it never meets a guest
  routerHost = 1;

  # rfc 1918: the house, the lab, the wireguard peers and every container bridge
  privateRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" ];
  # the owner's devices dialing in (instances/300-router/main.nix wg0)
  wireguardSubnet = "10.0.0.0/24";
  # headscale's tailnet (instances/138-internal-headscale), rfc 6598 carrier-grade nat: never the internet either
  tailnet = "100.64.0.0/10";
  # the internal ingress's own pages (its hand-written routers), relayed by the edge and named by the router's dns
  ingressPages = { dashboard = "traefik"; proxmox = "proxmox"; };

  # https://www.cloudflare.com/ips-v4/ as of 2026-10-06; the edge trusts their forwarded headers and nothing else
  cloudflareRanges = [
    "173.245.48.0/20" "103.21.244.0/22" "103.22.200.0/22" "103.31.4.0/22" "141.101.64.0/18" "108.162.192.0/18"
    "190.93.240.0/20" "188.114.96.0/20" "197.234.240.0/22" "198.41.128.0/17" "162.158.0.0/15" "104.16.0.0/13"
    "104.24.0.0/14" "172.64.0.0/13" "131.0.72.0/22"
  ];

  # protocol ports, the same on every host; a service's own port lives with the service (telemetry.nix, an instance's routes)
  ports = {
    ssh = 22;
    dns = 53;
    dhcpServer = 67;
    http = 80;
    rpcbind = 111;
    https = 443;
    nfs = 2049;
    swarmManager = 2377;
    vxlan = 4789;
    mdns = 5353;
    swarmGossip = 7946;
    proxmoxApi = 8006;
    nodeExporter = 9100;
    redis = 6379;
    traefikMetrics = 8082;
    minecraft = 25565;
    wireguard = 51820;
  };

  # -------------------------------------------------------------------------------------------------------------
  # INTERNAL
  # -------------------------------------------------------------------------------------------------------------

  cidr = import ./cidr.nix { inherit lib; };

  zoneOfRaw = name: z: {
    inherit name;
    inherit (z) bridge subnet;
    prefix = cidr.prefix z.subnet;
    routerIp = cidr.host z.subnet routerHost;
    interface = "ens${toString (nicPciSlotFirst + z.router_nic)}";
    # the vmid of the zone's ingress, a string like inventory keys; null: the zone publishes nothing itself
    ingress = if z.ingress == null then null else toString z.ingress;
    dhcpPool = if z.dhcp_pool == null then null else {
      first = cidr.host z.subnet z.dhcp_pool.first;
      last = cidr.host z.subnet z.dhcp_pool.last;
    };
    # guests meant to run in the zone, by address
    hosts = lib.sort (a: b: cidr.ipToInt a < cidr.ipToInt b) (map (v: v.ip)
      (lib.filter (v: v.type == name && v.enabled != "false") (lib.attrValues inventory)));
  };

  zones = lib.mapAttrs zoneOfRaw (lib.importJSON ../generated/zones.json);

  vmOf = id: inventory.${id} or (throw "net.nix: the inventory has no guest ${id}");
in
{
  inherit domain privateRanges tailnet cloudflareRanges ports zones ingressPages;
  cidrContains = cidr.contains;
  # the domain as an ldap base dn (authelia and its lldap, the proxmox realm)
  domainDn = lib.concatMapStringsSep "," (part: "dc=${part}") (lib.splitString "." domain);

  wireguard = {
    subnet = wireguardSubnet;
    address = cidr.host wireguardSubnet routerHost;
    prefix = cidr.prefix wireguardSubnet;
  };

  # the router's wan leg: the house lan and, through the fritzbox, the internet
  wan = {
    interface = "ens${toString nicPciSlotFirst}";
    inherit (site.lan) subnet gateway workstation proxmox;
    address = site.lan.router;
  };

  # a guest's address, and the same as a one-host source for a firewall or an allow list
  ipOf = id: (vmOf id).ip;
  hostSource = id: "${(vmOf id).ip}/32";
  zoneOf = id: zones.${(vmOf id).type} or (throw "net.nix: guest ${id} is in no zone (type ${(vmOf id).type})");
  # host name under the lab domain
  fqdn = host: "${host}.${domain}";
}
