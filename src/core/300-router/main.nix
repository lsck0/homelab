# the lab's router: nat, the zone firewall, dhcp, split-horizon dns, wireguard, the vpn and tor exits, ddns
#
# The policy is data (modules/flows.nix); this file renders it into nftables, in this order of the forward chain:
#   1. nixos' own `ct status dnat accept`: every port forward below, and the vpn exit's forwarded port
#   2. flows.forward, each flow one accept with its reason
#   3. the networks' defaults: trusted ones accept, the house lan reaches the zones it may, an isolated zone has
#      every private destination dropped and the internet allowed
#   4. nixos nat's own accepts, which the drops above must precede (lib.mkBefore; tests/policy/network.nix holds it)
# Sources are bound to their interface before any of it (table antispoof), and proxmox binds a guest to its address
# inside a zone (lib.tf FIREWALL).
#
# Egress classes (instance.nix `on`): a member's internet-bound traffic leaves through its exit or not at all,
# its lab traffic (any private destination) stays direct. vpn marks it into the tunnel's routing table; tor redirects
# its tcp into tor's TransPort and answers its dns from tor's DNSPort (coredns view), and the killswitch drops the
# rest (udp, icmp), which tor cannot carry. Transparent on the router, so a member needs no proxy setting per app and
# a program that ignores one leaks nothing; a socks proxy per app (prowlarr's, 130-internal-arr) isolates circuits
# per destination, which the transparent port does per client address only.
{ config, pkgs, lib, inventory, nasClients, site, catalog, lab, upstream, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  flows = import ../../modules/flows.nix { inherit lib net inventory catalog nasClients lab; };
  inherit (net) zones ports;
  wan = net.wan.interface;

  set = items: "{ ${lib.concatStringsSep ", " (map toString items)} }";
  ifOf = network: flows.networks.${network}.interface;
  privateRanges = set net.privateRanges;
  # every network but the house lan, which shares the wan
  labNetworks = lib.attrValues (removeAttrs flows.networks [ "lan" ]);

  # -------------------------------------------------------------------------------------------------------------
  # FIREWALL RENDERING
  # -------------------------------------------------------------------------------------------------------------

  addressesOf = e: if e.addresses == null then flows.networks.${e.network}.sources else e.addresses;
  # a flow with nobody on one side (no nas client in a zone, no enabled app) renders nothing, never `{ }`
  flowLive = f: addressesOf f.from != [ ] && (f ? to -> addressesOf f.to != [ ]);
  flowRules = f:
    let
      # a router service answers on the interface the flow comes in by: the dmz's dns is 10.200.0.1, never 10.100.0.1
      # (local delivery would accept any of the router's addresses); dhcp and mdns arrive as broadcast and multicast
      match = "iifname \"${ifOf f.from.network}\" ip saddr ${set (addressesOf f.from)}"
        + (if f ? to then " ip daddr ${set (addressesOf f.to)}" else " fib daddr . iif type { local, broadcast, multicast }");
    in
    lib.optionals (flowLive f) ([ "# ${f.why}" ]
      ++ lib.optional ((f.tcp or [ ]) != [ ]) "${match} tcp dport ${set f.tcp} accept"
      ++ lib.optional ((f.udp or [ ]) != [ ]) "${match} udp dport ${set f.udp} accept"
      ++ lib.optional (f.esp or false) "${match} meta l4proto esp accept");

  networkDefaults = name: n: [ "# ${name}" ] ++ (
    if n.reaches == "everything" then [ "iifname \"${n.interface}\" accept" ]
    else if n.reaches == "internet" then [
      "iifname \"${n.interface}\" ip daddr ${privateRanges} counter drop"
      # the house's wan or the vpn exit, whichever the guest's egress class routes it to
      "iifname \"${n.interface}\" accept"
    ]
    else [
      "iifname \"${n.interface}\" ip saddr ${set n.sources} oifname ${set (map (r: "\"${ifOf r}\"") n.reaches)} accept"
      # the internet and the rest of the house; port forwards passed as dnat above
      "iifname \"${n.interface}\" counter drop"
    ]);

  forwardRules = lib.concatStringsSep "\n" (lib.concatMap flowRules flows.forward
    ++ lib.concatLists (lib.mapAttrsToList networkDefaults flows.networks));
  inputRules = lib.concatStringsSep "\n" (lib.concatMap flowRules flows.router);

  # -------------------------------------------------------------------------------------------------------------
  # EGRESS CLASSES (an instance's `on`, collected by modules/lab `egress`)
  # -------------------------------------------------------------------------------------------------------------

  # the vpn exit: a mark selects a routing table whose default is the tunnel and whose fallback is a blackhole
  egressMarks = { vpn = { mark = 1; table = 100; }; };
  # ahead of the main table's rule (32766), after local (0)
  egressRulePriority = 101;
  # the blackhole only answers while the tunnel's own default (metric 1, egress-vpn.nix) is missing
  egressBlackholeMetric = 1000;
  vpnEntries = lib.filterAttrs (_: e: e.via == "vpn") lab.egress;
  membersOf = via: lib.sort (a: b: a < b) (map net.ipOf (lib.attrNames (lib.filterAttrs (_: e: e.via == via) lab.egress)));
  vpnMembers = membersOf "vpn";
  torMembers = membersOf "tor";
  vpnInbound = lib.filter (e: e.inbound) (lib.attrValues vpnEntries);
  vpnInboundIp = net.ipOf (toString (lib.head vpnInbound).vmid);
  vpnCfg = config.homelab.egress.vpn;
  # modules/egress-vpn.nix's tunnel
  vpnInterface = "wg-egress";
  # the provider's nat-pmp lease; the timer renews well inside it
  protonLeaseS = 60;

  # -------------------------------------------------------------------------------------------------------------
  # TOR (socks: prowlarr's indexers, one circuit per destination; the owner's own checks on 9050; the tor egress)
  # -------------------------------------------------------------------------------------------------------------

  torPorts = import ../../modules/tor-ports.nix;
  torFlowsOn = port: lib.filter (f: lib.elem port (f.tcp or [ ])) flows.router;
  # who flows.nix lets reach a tor listener: socks and the transparent port alike are tor's SocksPolicy
  torClients = lib.concatMap (f: addressesOf f.from) (torFlowsOn torPorts.socksIsolated ++ torFlowsOn torPorts.trans);
  # a redirect lands on the address of the interface it came in by: the router's own in each zone with members
  torTransAddresses = map (f: zones.${f.from.network}.routerIp) (torFlowsOn torPorts.trans);
  # coredns asks tor's DNSPort from loopback
  torDnsAddress = "127.0.0.1";
  torCookie = "/var/lib/tor/control_auth_cookie";
  torControlTimeoutS = 5;
  # tor-control <command>: one command on the control port, its answer on stdout
  torControl = pkgs.writeShellScript "tor-control" ''
    set -euo pipefail
    cookie=$(${pkgs.xxd}/bin/xxd -p -c 256 ${torCookie})
    printf 'AUTHENTICATE %s\r\n%s\r\nQUIT\r\n' "$cookie" "$1" | ${pkgs.netcat-gnu}/bin/nc -w ${toString torControlTimeoutS} 127.0.0.1 ${toString torPorts.control}
  '';
  # homelab_tor_circuit_established, the router's tor_unavailable alert (instance.nix)
  torTextfile = "tor";


  # -------------------------------------------------------------------------------------------------------------
  # DNS AND DDNS NAMES
  # -------------------------------------------------------------------------------------------------------------

  ingressIp = zone: net.ipOf zones.${zone}.ingress;
  hostsOf = side: lib.unique (map (r: r.host) (lib.attrValues catalog.${side}));
  # internal ingress routes without a catalog entry
  internalExtraHosts = lib.attrValues net.ingressPages;
  # the edge answers these itself
  installHosts = lib.attrNames (import ../../modules/install-hosts.nix);
  forwardHosts = lib.filter (h: h != null) (map (f: f.host) flows.portForwards);
  # names that skip the ingresses: the nas's smb, every lab-only tcp or udp route of an instance at its guest
  directHosts = { smb = net.ipOf lab.roles.nas; } // lib.mapAttrs' (_: r: lib.nameValuePair r.host (net.ipOf (toString r.vmid)))
    (lib.filterAttrs (_: r: r.vmid != null && r.publicPort == null) catalog.l4);

  # public names: the routes taking internet, proxied where they take cloudflare; install lines, the wireguard
  # endpoint and port forwards are raw by nature
  routeHosts = side: map (r: { inherit (r) host; proxied = lib.elem "cloudflare" r.on; })
    (lib.filter (r: lib.elem "internet" r.on) (lib.attrValues catalog.${side}));
  allRouteHosts = routeHosts "internal" ++ routeHosts "external"
    ++ map (host: { inherit host; proxied = true; }) internalExtraHosts;
  proxiedHosts = lib.unique (map (r: r.host) (lib.filter (r: r.proxied) allRouteHosts));
  rawHosts = lib.subtractLists proxiedHosts (lib.unique (map (r: r.host) (lib.filter (r: !r.proxied) allRouteHosts)
    ++ installHosts ++ forwardHosts ++ [ net.wan.publicHost ]));
  ddnsRecords = pkgs.writeText "ddns-records.json" (builtins.toJSON (
    map (h: { name = net.fqdn h; proxied = true; }) proxiedHosts
    ++ map (h: { name = net.fqdn h; proxied = false; }) rawHosts));

  hostLines = ip: names: lib.concatMapStrings (h: "      ${ip} ${net.fqdn h}\n") names;
  # the forwards a name leads to: inside the lab it resolves straight to the backend
  hostForwards = lib.filter (f: f.host != null) flows.portForwards;

  # the house's public address as the router learns it, a hosts line coredns serves as net.wan.publicHost
  publicAddressFile = "/run/public-address/hosts";
  publicAddressTimeoutS = 20;
  # an answer coredns keeps serving while every upstream is down
  dnsStaleS = 86400;

  # blocky's lists, fetched to disk so a restart during an outage keeps the last ones
  blocklistDir = "/var/lib/blocklists";
  blocklists = {
    stevenblack = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
    # hagezi dropped its hosts format; blocky reads the wildcard one (*.domain)
    hagezi-pro = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt";
  };
  blocklistTimeoutS = 120;

  # blocky on loopback, coredns' upstream for everything outside the lab domain
  blockyAddress = "127.0.0.1:5335";
  blockyUpstream = "tcp-tls:1.1.1.1:853";
  # dns over tls when blocky is down: a fallback, but never a plaintext one
  dnsFallback = { servers = [ "tls://1.1.1.1" "tls://1.0.0.1" ]; name = "cloudflare-dns.com"; };
  # an egress class's members resolve through its exit and fail with it, so no name they look up leaves through the house
  viewOf = members: lib.concatMapStringsSep " || " (ip: "incidr(client_ip(), '${ip}/32')") members;

  # -------------------------------------------------------------------------------------------------------------
  # WAN LIMITS
  # -------------------------------------------------------------------------------------------------------------

  # per internet source: far above a browser's kept-alive handful, far below a flood
  wanSynPerSecond = 50;
  wanSynBurst = 100;
  wanConnsMax = 200;
  # sources tracked per meter: the conntrack table's headroom above, at a quarter of nf_conntrack_max
  wanMeterSize = 65535;
  # one forward's concurrent connections over every client: a game server's players and a flood's leftovers alike
  forwardConnsMax = 256;
  # client ips of new connections to a forward, logged; the rate bounds the journal under a flood
  forwardLogPerMinute = 60;
  # the networks a port forward answers: the wan and, hairpinned, the trusted ones; never a dmz
  forwardSources = set (map (n: "\"${n.interface}\"") (lib.attrValues (lib.filterAttrs (name: n: name == "lan" || n.reaches == "everything") flows.networks)));
  conntrackMax = 262144;
  # a forward to several guests (an app's nodes) keeps each client on one of them
  dnatTarget = f: if lib.length f.addresses == 1 then "${lib.head f.addresses}:${toString f.targetPort}"
    else "jhash ip saddr mod ${toString (lib.length f.addresses)} map { "
      + lib.concatStringsSep ", " (lib.imap0 (i: ip: "${toString i} : ${ip}") f.addresses) + " } : ${toString f.targetPort}";

  # a dhcp discover's source before it has an address
  dhcpUnaddressed = "0.0.0.0";
in {
  imports = [ ./lib/onion-services.nix ];

  assertions = [
    {
      assertion = vpnMembers == [ ] || vpnCfg.enable;
      message = "the instances' egress routes ${toString vpnMembers} through the VPN, but homelab.egress.vpn is not enabled on the router.";
    }
    {
      assertion = lib.length vpnInbound <= 1;
      message = "egress: the provider forwards one port per tunnel, so at most one instance's egress is inbound.";
    }
  ];

  # mdns on the house lan only, the fritzbox shows "luca-router"
  services.avahi = {
    enable = true;
    allowInterfaces = [ wan ];
    # the default opens 5353 on every interface, dmz and wg-egress included; flows.nix opens it on the lan
    openFirewall = false;
    ipv4 = true;
    ipv6 = false;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      hinfo = true;
    };
  };

  # NETWORK INTERFACES: the wan, then one leg per zone at host 1 (zones.json)
  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.useDHCP = false;
  networking.interfaces = {
    ${wan}.ipv4.addresses = [{ address = net.wan.address; prefixLength = lib.toInt (lib.last (lib.splitString "/" net.wan.subnet)); }];
  } // lib.mapAttrs' (_: z: lib.nameValuePair z.interface {
    ipv4.addresses = [{ address = z.routerIp; prefixLength = z.prefix; }];
  }) zones;
  networking.defaultGateway = { address = net.wan.gateway; interface = wan; };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    # a syn flood is answered statelessly
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_max_syn_backlog" = 4096;
    "net.ipv4.tcp_synack_retries" = 2;
    # loose: strict drops every vpn reply; sources are bound to interfaces by table antispoof instead
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    # source routing and redirects let remotes steer
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    # no amplification
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.netfilter.nf_conntrack_max" = conntrackMax;
  };

  # ANTI-SPOOFING: a source arrives only on the interface it belongs to, before routing, input or forward see it
  networking.nftables.tables.antispoof = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        ip saddr ${dhcpUnaddressed} udp dport ${toString ports.dhcpServer} return
    '' + lib.concatMapStrings (n: ''
        iifname "${n.interface}" ip saddr != ${set n.sources} counter drop
    '') labNetworks + ''
        # the wan carries the internet and the house, never a lab address
        iifname "${wan}" ip saddr ${set (lib.concatMap (n: n.sources) labNetworks)} counter drop
      }
    '';
  };

  # EGRESS CLASSES: vpn marks by source into a table ending in a blackhole, tor redirects tcp into its TransPort
  networking.nftables.tables.egress = lib.mkIf (vpnMembers != [ ] || torMembers != [ ]) {
    family = "ip";
    content = lib.optionalString (vpnMembers != [ ]) ''
      chain premark {
        type filter hook prerouting priority mangle; policy accept;
        # never divert lab or house traffic: replies to them would blackhole
        ip daddr ${privateRanges} return
        ip saddr ${set vpnMembers} meta mark set ${toString egressMarks.vpn.mark}
      }
    '' + lib.optionalString (torMembers != [ ]) ''
      chain torredirect {
        type nat hook prerouting priority dstnat; policy accept;
        ip saddr ${set torMembers} ip daddr != ${privateRanges} meta l4proto tcp counter redirect to :${toString torPorts.trans}
      }
    '' + ''
      # stateless, ahead of nixos-fw: a lost rule or route must never leak through the house
      chain killswitch {
        type filter hook forward priority filter - 5; policy accept;
    '' + lib.optionalString (vpnMembers != [ ]) ''
        ip saddr ${set vpnMembers} oifname "${wan}" ip daddr != ${privateRanges} counter drop
    '' + lib.optionalString (torMembers != [ ]) ''
        # through no interface: what tor carries never reaches forward, the rest has no exit
        ip saddr ${set torMembers} ip daddr != ${privateRanges} counter drop
    '' + ''
      }
    '';
  };

  # marked traffic routes through the tunnel table
  systemd.services.egress-policy = lib.mkIf (vpnMembers != [ ]) {
    description = "Policy routing for the VPN egress class";
    after = [ "network-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    startLimitIntervalSec = 0;
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 5; };
    script = ''
      set -euo pipefail
      table=${toString egressMarks.vpn.table}
      # ip rule has no replace: drop the previous start's rule, absent on the first one
      ip rule del fwmark ${toString egressMarks.vpn.mark} table $table 2>/dev/null || true
      ip rule add fwmark ${toString egressMarks.vpn.mark} table $table priority ${toString egressRulePriority}
      # tunnel down: drop, never fall back to the house
      ip route replace blackhole default metric ${toString egressBlackholeMetric} table $table

      # rp_filter checks a reply's source against the marked table: every directly connected network
      ${lib.concatMapStrings (n: ''
        ip route replace ${lib.head n.sources} dev ${n.interface} table $table
      '') (lib.attrValues (removeAttrs flows.networks [ "wireguard" ]))}
    '';
  };

  # the shared exit (modules/egress-vpn.nix)
  homelab.egress.vpn = {
    enable = true;
    table = egressMarks.vpn.table;
    # former vm-112 key, clients cannot share one
    privateKeyFile = config.sops.secrets.protonvpn-private-key.path;
    address = "10.2.0.2/32";
    publicKey = "36G8+pInNcPK9F1TpHglWs9Pk5uJOY9o8SCNrCBgvHE=";
    # CH#684; an address, since dns is in the tunnel
    endpoint = "89.222.96.158:51820";
  };
  sops.secrets.protonvpn-private-key = { };

  # the exit's forwarded port leads to the inbound member; the lease changes the port, renewal rewrites the set
  networking.nftables.tables.proton-port = lib.mkIf (vpnInbound != [ ]) {
    family = "ip";
    content = ''
      set proton_port {
        type inet_service;
      }
      chain prerouting {
        type nat hook prerouting priority dstnat - 2; policy accept;
        iifname "${vpnInterface}" tcp dport @proton_port dnat to ${vpnInboundIp}
        iifname "${vpnInterface}" udp dport @proton_port dnat to ${vpnInboundIp}
      }
    '';
  };

  systemd.services.protonvpn-port = lib.mkIf (vpnInbound != [ ]) {
    description = "Renew the Proton forwarded port and publish it";
    after = [ "wireguard-${vpnInterface}.service" ];
    path = [ pkgs.libnatpmp pkgs.nftables pkgs.curl pkgs.coreutils pkgs.gnused pkgs.jq ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "protonvpn"; };
    environment = {
      PEER_HOST = vpnInboundIp;
      GATEWAY = vpnCfg.gateway;
      LEASE_S = toString protonLeaseS;
    };
    script = "exec ${pkgs.bash}/bin/bash ${./lib/protonvpn-port.sh}";
  };
  systemd.timers.protonvpn-port = lib.mkIf (vpnInbound != [ ]) {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "90s"; OnUnitActiveSec = "45s"; AccuracySec = "5s"; };
  };

  # TOR: socks, and the transparent and dns ports of the tor egress members
  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;
    client = {
      enable = true;
      # the owner's check from the router itself (hermes skill downloads); the firewall opens it to nobody
      socksListenAddress = { addr = zones.internal.routerIp; port = torPorts.socks; };
    };
    settings = {
      SocksPolicy = map (ip: "accept ${ip}") (torClients ++ [ zones.internal.routerIp torDnsAddress ]) ++ [ "reject *" ];
      # one circuit per indexer: no exit sees two of them from one client
      SOCKSPort = [{
        addr = zones.internal.routerIp;
        port = torPorts.socksIsolated;
        IsolateDestAddr = true;
        IsolateDestPort = true;
      }];
      TransPort = map (addr: { inherit addr; port = torPorts.trans; }) torTransAddresses;
      DNSPort = lib.optional (torMembers != [ ]) { addr = torDnsAddress; port = torPorts.dns; };
      ClientUseIPv6 = false;
      # path rotation
      MaxCircuitDirtiness = 600;
      NewCircuitPeriod = 120;
      CircuitBuildTimeout = 30;
      ControlPort = [{ addr = "127.0.0.1"; port = torPorts.control; }];
      CookieAuthentication = true;
    };
  };

  # dirtiness only affects new streams, so force newnym
  systemd.services.tor-new-circuits = {
    description = "Ask Tor for a fresh set of circuits";
    after = [ "tor.service" ];
    requires = [ "tor.service" ];
    serviceConfig.Type = "oneshot";
    script = "${torControl} 'SIGNAL NEWNYM'";
  };
  systemd.timers.tor-new-circuits = {
    wantedBy = [ "timers.target" ];
    # jitter so rotation is no clock fingerprint
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "30m"; RandomizedDelaySec = "10m"; };
  };

  # tor down or without a circuit: the gauge says 0, never its last 1
  homelab.textfiles = [ torTextfile ];
  systemd.services.tor-status = {
    description = "Publish whether tor has a circuit";
    after = [ "tor.service" ];
    path = [ pkgs.coreutils pkgs.gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      metrics=${config.homelab.textfileDir}/${torTextfile}.prom
      established=0
      if answer=$(${torControl} 'GETINFO status/circuit-established') && grep -q '^250-status/circuit-established=1' <<<"$answer"; then
        established=1
      fi
      printf '# TYPE homelab_tor_circuit_established gauge\nhomelab_tor_circuit_established %s\n' "$established" > "$metrics.tmp"
      mv "$metrics.tmp" "$metrics"
    '';
  };
  systemd.timers.tor-status = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "5m"; OnUnitActiveSec = "5m"; };
  };

  # every port is opened by flows.nix `router` below, per network and source
  services.openssh.openFirewall = false;
  services.prometheus.exporters.node.openFirewall = false;

  # NAT: every zone leaves through the wan masqueraded; port forwards are the table below
  networking.nat = {
    enable = true;
    externalInterface = wan;
    internalInterfaces = map (n: n.interface) labNetworks;
    # nixos forwardPorts would match all wan traffic
    forwardPorts = [ ];
  };

  networking.nftables.enable = true;
  # nixos' stop deletes every table while forwarding stays on, so a restart forwarded unfiltered between stop and
  # start; start already replaces the tables in one transaction, so the router is never without its ruleset
  systemd.services.nftables.serviceConfig.ExecStop = lib.mkForce [ ];
  networking.firewall = {
    # strict drops every vpn reply
    checkReversePath = "loose";
    enable = true;
    filterForward = true;
    extraInputRules = inputRules;
    # ahead of the nat module's own accepts, which would otherwise let a dmz reach the house
    extraForwardRules = lib.mkBefore forwardRules;
  };

  # per internet source, ahead of every accept and dnat; exempt: the house lan and cloudflare (the edge limits it)
  networking.nftables.tables.wan-limits = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority filter - 1; policy accept;
        ip saddr ${set [ net.wan.subnet ]} return
        ip saddr ${set net.cloudflareRanges} return
        iifname "${wan}" tcp flags & (fin|syn|rst|ack) == syn \
          meter wan-syn size ${toString wanMeterSize} { ip saddr limit rate over ${toString wanSynPerSecond}/second burst ${toString wanSynBurst} packets } \
          counter drop
        iifname "${wan}" ct state new \
          meter wan-conns size ${toString wanMeterSize} { ip saddr ct count over ${toString wanConnsMax} } \
          counter drop
      }
    '';
  };

  # PORT FORWARDS: the wan address only, from forwardSources; capped and its clients logged where its route opts in
  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
    '' + lib.concatMapStrings (f: let match = "iifname ${forwardSources} ip daddr ${net.wan.address} ${f.proto} dport ${toString f.port}"; in ''
        # ${f.why}
    '' + lib.optionalString (lib.elem "inflightLimit" f.on) ''
        ${match} ct state new ct count over ${toString forwardConnsMax} counter drop
    '' + lib.optionalString (lib.elem "accessLog" f.on) ''
        ${match} ct state new limit rate ${toString forwardLogPerMinute}/minute log prefix "forward ${toString f.port}: "
    '' + ''
        ${match} dnat to ${dnatTarget f}
    '') flows.portForwards + ''
      }
    '';
  };

  # DHCP SERVER (KEA): every zone with a pool, never on a guest's static address (lib.tf invariants)
  services.kea.dhcp4 = let pooled = lib.filter (z: z.dhcpPool != null) (lib.attrValues zones); in {
    enable = true;
    settings = {
      valid-lifetime = 3600;
      renew-timer = 900;
      rebind-timer = 1800;
      interfaces-config.interfaces = map (z: z.interface) pooled;
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };
      subnet4 = lib.imap1 (id: z: {
        inherit id;
        inherit (z) subnet interface;
        pools = [{ pool = "${z.dhcpPool.first} - ${z.dhcpPool.last}"; }];
        option-data = [
          { name = "routers"; data = z.routerIp; }
          { name = "domain-name-servers"; data = z.routerIp; }
        ];
      }) pooled;
    };
  };

  # DNS BLOCKLIST + DOT UPSTREAM (BLOCKY, loopback only)
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = blockyAddress;
      upstreams.groups.default = [
        blockyUpstream
        "tcp-tls:9.9.9.9:853"
      ];
      # bootstrap dot hostnames without a dns loop
      bootstrapDns = [
        { upstream = blockyUpstream; ips = [ "1.1.1.1" ]; }
      ];
      blocking = {
        # blocklists-fetch restarts blocky on a new list
        denylists.ads = map (name: "${blocklistDir}/${name}") (lib.attrNames blocklists);
        clientGroupsBlock.default = [ "ads" ];
      };
      caching = { minTime = "5m"; maxTime = "30m"; prefetching = true; };
    };
  };

  # DNS SERVER (COREDNS): split horizon for the lab domain, blocky for the rest, its exit's resolver for an egress member
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      ${net.domain}:53 {
        hosts ${publicAddressFile} {
          # internal routes -> the internal ingress
    '' + hostLines (ingressIp "internal") (hostsOf "internal" ++ internalExtraHosts) + ''
          # public routes and port forwards -> the edge
    '' + hostLines (ingressIp "external") (hostsOf "external" ++ installHosts) + ''
          # names that skip the ingresses
    '' + lib.concatStrings (lib.mapAttrsToList (h: ip: hostLines ip [ h ]) directHosts)
      + lib.concatMapStrings (f: lib.concatMapStrings (ip: hostLines ip [ f.host ]) f.addresses) hostForwards + ''
          fallthrough
        }
    '' + lib.concatMapStrings (f: ''
        template IN SRV ${f.srv}.${net.fqdn f.host} {
          answer "{{ .Name }} 3600 IN SRV 0 0 ${toString f.port} ${net.fqdn f.host}."
        }
    '') (lib.filter (f: f.srv != null) hostForwards) + ''
        # unlisted names (mx, txt, public-only records) resolve like the rest
        forward . ${blockyAddress}
      }
    '' + lib.optionalString (vpnMembers != [ ]) ''

      .:53 {
        view vpn {
          expr ${viewOf vpnMembers}
        }
        forward . ${vpnCfg.dns}
      }
    '' + lib.optionalString (torMembers != [ ]) ''

      .:53 {
        view tor {
          expr ${viewOf torMembers}
        }
        forward . ${torDnsAddress}:${toString torPorts.dns}
      }
    '' + ''

      .:53 {
        # blocky first; dns survives it, encrypted
        forward . ${blockyAddress} ${lib.concatStringsSep " " dnsFallback.servers} {
          tls_servername ${dnsFallback.name}
          policy sequential
          health_check 5s
        }
        cache 300 {
          serve_stale ${toString dnsStaleS}s
        }
      }
    '';
  };

  # server pubkey: wg show wg0 public-key
  sops.secrets.wireguard-private-key = { };
  sops.secrets.cloudflare-token = { };

  # PUBLIC ADDRESS: learned here once, served to the lab by coredns, pushed to cloudflare by ddns
  systemd.tmpfiles.rules = [ "d ${dirOf publicAddressFile} 0755 root root -" "f ${publicAddressFile} 0644 root root -" "d ${blocklistDir} 0755 root root -" ];
  systemd.services.public-address = {
    description = "Learn the house's public address";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onSuccess = [ "ddns-cloudflare.service" ];
    path = [ pkgs.curl pkgs.coreutils ];
    # ipify down: the last address stays published
    serviceConfig = { Type = "oneshot"; SuccessExitStatus = [ upstream.unavailable ]; };
    script = ''
      ip=$(${upstream.run} ipify curl -sSf --max-time ${toString publicAddressTimeoutS} ${lab.upstreams.ipify.url})
      if ! [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ipify answered no ipv4 address: '$ip'" >&2
        exit 1
      fi
      printf '%s %s\n' "$ip" ${net.fqdn net.wan.publicHost} > ${publicAddressFile}.tmp
      mv ${publicAddressFile}.tmp ${publicAddressFile}
    '';
  };
  systemd.timers.public-address = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "1min"; OnUnitActiveSec = "5min"; };
  };

  # DDNS (CLOUDFLARE): every public host, proxied or raw as its route says (lib/ddns-cloudflare.sh)
  systemd.services.ddns-cloudflare = {
    description = "Point the ${net.domain} A records at the current public IP";
    path = [ pkgs.curl pkgs.jq pkgs.findutils pkgs.coreutils ];
    environment = {
      DDNS_RECORDS = ddnsRecords;
      DDNS_ZONE = net.domain;
      DDNS_TOKEN_FILE = config.sops.secrets.cloudflare-token.path;
      DDNS_ADDRESS_FILE = publicAddressFile;
      DDNS_STATE_DIR = "/run/ddns-cloudflare";
    };
    # /run starts empty, so every boot does a full sync; cloudflare down: the records keep the last address
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "ddns-cloudflare";
      RuntimeDirectoryPreserve = true;
      SuccessExitStatus = [ upstream.unavailable ];
    };
    script = "exec ${upstream.run} cloudflare ${pkgs.bash}/bin/bash ${./lib/ddns-cloudflare.sh}";
  };

  # BLOCKLISTS: fetched to disk; a failed fetch keeps the last list
  systemd.services.blocklists-fetch = {
    description = "Fetch blocky's deny lists";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.diffutils pkgs.systemd ];
    serviceConfig = { Type = "oneshot"; SuccessExitStatus = [ upstream.unavailable ]; };
    script = ''
      status=0
      changed=0
      # a failed fetch keeps the last list
      for list in ${lib.escapeShellArgs (lib.mapAttrsToList (name: url: "${name}=${url}") blocklists)}; do
        file=${blocklistDir}/''${list%%=*}
        rc=0
        ${upstream.run} githubusercontent curl -sSf --max-time ${toString blocklistTimeoutS} -o "$file.part" "''${list#*=}" || rc=$?
        if [ "$rc" -ne 0 ]; then
          rm -f "$file.part"
          status=$rc
        elif cmp -s "$file.part" "$file"; then
          rm -f "$file.part"
        else
          mv "$file.part" "$file"
          changed=1
        fi
      done
      # blocky reads its lists at start; coredns answers from its fallback for the moment it restarts
      if [ "$changed" -eq 1 ]; then systemctl try-restart blocky.service; fi
      exit "$status"
    '';
  };
  systemd.timers.blocklists-fetch = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnCalendar = "daily"; RandomizedDelaySec = "1h"; Persistent = true; };
  };

  # WIREGUARD VPN (clients need DNS = 10.0.0.1)
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${net.wireguard.address}/${toString net.wireguard.prefix}" ];
    listenPort = ports.wireguard;
    privateKeyFile = config.sops.secrets.wireguard-private-key.path;
    peers = [
      { # laptop
        publicKey = "uS6fCRVw/IvsfT4R7r0coMLxWl9+gHRY0H/KlNFkBVs=";
        allowedIPs = [ "10.0.0.2/32" ];
      }
      { # phone
        publicKey = "lplUjlL/gPLRaSwi/wbtmpZ34BCinSq9bY9dmwxXh3s=";
        allowedIPs = [ "10.0.0.3/32" ];
      }
      { # tablet
        publicKey = "AW4t+4glZqmUl8ZAtrq60K/GTDmzZJisz1+6EqYnmzI=";
        allowedIPs = [ "10.0.0.4/32" ];
      }
      { # pc, config in secrets repo wg0.pc.conf
        publicKey = "rvtqHdSDK3JGZhZkzVYIcb9gKHiZUTsenfpJtm4adT0=";
        allowedIPs = [ "10.0.0.5/32" ];
      }
    ];
  };

  # wol-pc wakes luca-pc from the vpn; its mac is a device identity, kept out of the public repo
  sops.secrets.workstation-mac = { };
  # a command, not a shell alias: `ssh <router> wol-pc` runs no profile
  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool
    (writeShellApplication {
      name = "wol-pc";
      runtimeInputs = [ wakeonlan ];
      text = "wakeonlan \"$(cat ${config.sops.secrets.workstation-mac.path})\"";
    })
  ];
}
