# the lab's router: nat, the zone firewall, dhcp, split-horizon dns, wireguard, the vpn exit, ddns
#
# The policy is data (modules/flows.nix); this file renders it into nftables, in this order of the forward chain:
#   1. nixos' own `ct status dnat accept`: every port forward below, and the vpn exit's forwarded port
#   2. flows.forward, each flow one accept with its reason
#   3. the networks' defaults: trusted ones accept, the house lan reaches the zones it may, an isolated zone has
#      every private destination dropped and the internet allowed
#   4. nixos nat's own accepts, which the drops above must precede (lib.mkBefore; tests/policy/network.nix holds it)
# Sources are bound to their interface before any of it (table antispoof), and proxmox binds a guest to its address
# inside a zone (lib.tf FIREWALL).
{ config, pkgs, lib, inventory, nasClients, site, catalog, lab, ... }:
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
  # EGRESS CLASSES (an instance's `egress`, collected by modules/lab)
  # -------------------------------------------------------------------------------------------------------------

  # the vpn exit: a mark selects a routing table whose default is the tunnel and whose fallback is a blackhole
  egressMarks = { vpn = { mark = 1; table = 100; }; };
  # ahead of the main table's rule (32766), after local (0)
  egressRulePriority = 101;
  # the blackhole only answers while the tunnel's own default (metric 1, egress-vpn.nix) is missing
  egressBlackholeMetric = 1000;
  vpnEntries = lib.filterAttrs (_: e: e.via == "vpn") lab.egress;
  vpnMembers = lib.sort (a: b: a < b) (map (e: net.ipOf (toString e.vmid)) (lib.attrValues vpnEntries));
  vpnInbound = lib.filter (e: e.inbound) (lib.attrValues vpnEntries);
  vpnInboundIp = net.ipOf (toString (lib.head vpnInbound).vmid);
  vpnCfg = config.homelab.egress.vpn;
  # modules/egress-vpn.nix's tunnel
  vpnInterface = "wg-egress";
  # the provider's nat-pmp lease; the timer renews well inside it
  protonLeaseS = 60;

  # -------------------------------------------------------------------------------------------------------------
  # TOR (socks only: prowlarr's indexers, one circuit per destination; the owner's own checks on 9050)
  # -------------------------------------------------------------------------------------------------------------

  torPorts = import ../../modules/tor-ports.nix;
  torSocksClients = lib.concatMap (f: addressesOf f.from)
    (lib.filter (f: lib.elem torPorts.socksIsolated (f.tcp or [ ])) flows.router);

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
  # names that skip the ingresses
  directHosts = { smb = net.ipOf (toString lab.routes.nas.vmid); sccache = net.ipOf (toString lab.routes.attic.vmid); };

  # proxied unless a route opts out; install lines, the wireguard endpoint and port forwards are raw by nature
  routeHosts = side: lib.mapAttrsToList (_: r: { inherit (r) host; proxied = r.off.cloudflare == null; }) catalog.${side};
  allRouteHosts = routeHosts "internal" ++ routeHosts "external"
    ++ map (host: { inherit host; proxied = true; }) internalExtraHosts;
  proxiedHosts = lib.unique (map (r: r.host) (lib.filter (r: r.proxied) allRouteHosts));
  rawHosts = lib.subtractLists proxiedHosts (lib.unique (map (r: r.host) (lib.filter (r: !r.proxied) allRouteHosts)
    ++ installHosts ++ forwardHosts ++ [ "wg" "*" ]));
  ddnsRecords = pkgs.writeText "ddns-records.json" (builtins.toJSON (
    map (h: { name = net.fqdn h; proxied = true; }) proxiedHosts
    ++ map (h: { name = net.fqdn h; proxied = false; }) rawHosts));

  hostLines = ip: names: lib.concatMapStrings (h: "      ${ip} ${net.fqdn h}\n") names;
  # the forwards a name leads to: inside the lab it resolves straight to the backend
  hostForwards = lib.filter (f: f.host != null) flows.portForwards;

  # blocky on loopback, coredns' upstream for everything outside the lab domain
  blockyAddress = "127.0.0.1:5335";
  blockyUpstream = "tcp-tls:1.1.1.1:853";
  # dns over tls when blocky is down: a fallback, but never a plaintext one
  dnsFallback = { servers = [ "tls://1.1.1.1" "tls://1.0.0.1" ]; name = "cloudflare-dns.com"; };
  # vpn members resolve inside the tunnel and fail with it, so no name they look up leaves through the house
  vpnView = lib.concatMapStringsSep " || " (ip: "incidr(client_ip(), '${ip}/32')") vpnMembers;

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

  # EGRESS CLASSES: mark by source, the marked table ends in a blackhole
  networking.nftables.tables.egress = lib.mkIf (vpnMembers != [ ]) {
    family = "ip";
    content = ''
      chain premark {
        type filter hook prerouting priority mangle; policy accept;
        # never divert lab or house traffic: replies to them would blackhole
        ip daddr ${privateRanges} return
        ip saddr ${set vpnMembers} meta mark set ${toString egressMarks.vpn.mark}
      }
      # stateless, ahead of nixos-fw: a lost rule or route must never leak through the house
      chain killswitch {
        type filter hook forward priority filter - 5; policy accept;
        ip saddr ${set vpnMembers} oifname "${wan}" ip daddr != ${privateRanges} counter drop
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

  # TOR SOCKS
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
      SocksPolicy = map (ip: "accept ${ip}") (torSocksClients ++ [ zones.internal.routerIp ]) ++ [ "reject *" ];
      # one circuit per indexer: no exit sees two of them from one client
      SOCKSPort = [{
        addr = zones.internal.routerIp;
        port = torPorts.socksIsolated;
        IsolateDestAddr = true;
        IsolateDestPort = true;
      }];
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
    path = [ pkgs.coreutils pkgs.netcat-gnu pkgs.xxd ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
      printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" | nc -w 5 127.0.0.1 ${toString torPorts.control}
    '';
  };
  systemd.timers.tor-new-circuits = {
    wantedBy = [ "timers.target" ];
    # jitter so rotation is no clock fingerprint
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "30m"; RandomizedDelaySec = "10m"; };
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

  # PORT FORWARDS: the wan address only, from forwardSources; each capped and its clients logged unless its route's `off`
  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
    '' + lib.concatMapStrings (f: let match = "iifname ${forwardSources} ip daddr ${net.wan.address} ${f.proto} dport ${toString f.port}"; in ''
        # ${f.why}
    '' + lib.optionalString (f.off.inflightLimit or null == null) ''
        ${match} ct state new ct count over ${toString forwardConnsMax} counter drop
    '' + lib.optionalString (f.off.accessLog or null == null) ''
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
        denylists.ads = [
          "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
          "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt"
        ];
        clientGroupsBlock.default = [ "ads" ];
        loading.downloads = { timeout = "60s"; attempts = 3; };
      };
      caching = { minTime = "5m"; maxTime = "30m"; prefetching = true; };
    };
  };

  # DNS SERVER (COREDNS): split horizon for the lab domain, blocky for the rest, the tunnel's resolver for vpn members
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      ${net.domain}:53 {
        hosts {
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
          expr ${vpnView}
        }
        forward . ${vpnCfg.dns}
      }
    '' + ''

      .:53 {
        # blocky first; dns survives it, encrypted
        forward . ${blockyAddress} ${lib.concatStringsSep " " dnsFallback.servers} {
          tls_servername ${dnsFallback.name}
          policy sequential
          health_check 5s
        }
        cache 300
      }
    '';
  };

  # server pubkey: wg show wg0 public-key
  sops.secrets.wireguard-private-key = { };
  sops.secrets.cloudflare-token = { };

  # DDNS (CLOUDFLARE): every catalog host, proxied or raw as its route says (lib/ddns-cloudflare.sh)
  systemd.services.ddns-cloudflare = {
    description = "Point the ${net.domain} A records at the current public IP";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.findutils pkgs.coreutils ];
    environment = {
      DDNS_RECORDS = ddnsRecords;
      DDNS_ZONE = net.domain;
      DDNS_TOKEN_FILE = config.sops.secrets.cloudflare-token.path;
      DDNS_STATE_DIR = "/run/ddns-cloudflare";
    };
    # /run starts empty, so every boot does a full sync
    serviceConfig = { Type = "oneshot"; RuntimeDirectory = "ddns-cloudflare"; RuntimeDirectoryPreserve = true; };
    script = "exec ${pkgs.bash}/bin/bash ${./lib/ddns-cloudflare.sh}";
  };
  systemd.timers.ddns-cloudflare = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
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

  # wol-pc wakes luca-pc from the vpn
  environment.etc."profile.d/wol.sh".text = ''
    alias wol-pc='wakeonlan ${site.lan.workstationMac}'
  '';

  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool wakeonlan
  ];
}
