# the lab's router: nat, the zone firewall, dhcp, split-horizon dns, wireguard, the vpn and tor exits, ddns
#
# ordering: the forward chain is nixos' `ct status dnat accept`, then flows.forward, then the networks' defaults, then
# nixos nat's own accepts, which the drops must precede (lib.mkBefore; tests/policy/network.nix holds it).
# egress classes: a member's internet traffic leaves through its exit or not at all, transparently, so a program that
# ignores proxy settings leaks nothing; the killswitch drops what tor cannot carry (udp, icmp).
{
  config,
  pkgs,
  lib,
  inventory,
  nasClients,
  site,
  catalog,
  lab,
  upstream,
  ...
}:
let
  net = import ../../../modules/net.nix { inherit lib inventory site; };
  flows = import ../../../modules/flows.nix {
    inherit
      lib
      net
      inventory
      catalog
      nasClients
      lab
      ;
  };
  service = import ../../../modules/service.nix { inherit lib; };
  inherit (net) zones ports;
  wan = net.wan.interface;

  set = items: "{ ${lib.concatStringsSep ", " (map toString items)} }";
  ifOf = network: flows.networks.${network}.interface;
  privateRanges = set net.privateRanges;
  # the house lan shares the wan
  labNetworks = lib.attrValues (removeAttrs flows.networks [ "lan" ]);

  addressesOf = e: if e.addresses == null then flows.networks.${e.network}.sources else e.addresses;
  # a flow with nobody on one side (no nas client in a zone, no enabled app) renders nothing, never `{ }`
  flowLive = f: addressesOf f.from != [ ] && (f ? to -> addressesOf f.to != [ ]);
  flowRules =
    f:
    let
      # a router service answers on the interface the flow comes in by: the dmz's dns is 10.200.0.1, never 10.100.0.1
      # (local delivery would accept any of the router's addresses); dhcp and mdns arrive as broadcast and multicast
      match =
        "iifname \"${ifOf f.from.network}\" ip saddr ${set (addressesOf f.from)}"
        + (if f ? to then " ip daddr ${set (addressesOf f.to)}" else " fib daddr . iif type { local, broadcast, multicast }");
    in
    lib.optionals (flowLive f) (
      [ "# ${f.why}" ]
      ++ lib.optional ((f.tcp or [ ]) != [ ]) "${match} tcp dport ${set f.tcp} accept"
      ++ lib.optional ((f.udp or [ ]) != [ ]) "${match} udp dport ${set f.udp} accept"
      ++ lib.optional (f.esp or false) "${match} meta l4proto esp accept"
      ++ lib.optional (f.icmp or false) "${match} icmp type echo-request accept"
    );

  # a refusal between the networks counts by its source network (forward-deny-textfile) and logs, rate limited; the
  # limit lives on a rule of its own, so a flood past it is still dropped
  denyCounterOf = network: "fwd-deny-${network}";
  denyingNetworks = lib.attrNames (lib.filterAttrs (_: n: n.reaches != "everything") flows.networks);
  denyRules = network: match: [
    "${match} limit rate ${toString forwardLogPerMinute}/minute log prefix \"fwd-deny ${network}: \" level info"
    "${match} counter name \"${denyCounterOf network}\" drop"
  ];
  networkDefaults =
    name: n:
    let
      from = "iifname \"${n.interface}\"";
    in
    [ "# ${name}" ]
    ++ (
      if n.reaches == "everything" then
        [ "${from} accept" ]
      else if n.reaches == "internet" then
        denyRules name "${from} ip daddr ${privateRanges}" ++ [ "${from} accept" ]
      else
        [ "${from} ip saddr ${set n.sources} oifname ${set (map (r: "\"${ifOf r}\"") n.reaches)} accept" ]
        ++ denyRules name from
    );
  forwardDenyTextfile = "forward-deny";

  forwardRules = lib.concatStringsSep "\n" (
    lib.concatMap flowRules flows.forward ++ lib.concatLists (lib.mapAttrsToList networkDefaults flows.networks)
  );
  inputRules = lib.concatStringsSep "\n" (lib.concatMap flowRules flows.router);

  egressMarks = {
    vpn = {
      mark = 1;
      table = 100;
    };
  };
  # ahead of the main table's rule (32766), after local (0)
  egressRulePriority = 101;
  # the blackhole only answers while the tunnel's own default (metric 1, egress-vpn.nix) is missing
  egressBlackholeMetric = 1000;
  vpnEntries = lib.filterAttrs (_: e: e.via == "vpn") lab.egress;
  membersOf =
    via: lib.sort (a: b: a < b) (map net.ipOf (lib.attrNames (lib.filterAttrs (_: e: e.via == via) lab.egress)));
  vpnMembers = membersOf "vpn";
  torMembers = membersOf "tor";
  # a parked guest takes no forwarded port: renewing one for it only fails
  vpnInbound = lib.filter (e: e.inbound && lab.inventory.${toString e.vmid}.powered) (lib.attrValues vpnEntries);
  vpnInboundIp = net.ipOf (toString (lib.head vpnInbound).vmid);
  vpnCfg = config.homelab.egress.vpn;
  vpnInterface = "wg-egress";
  # the provider's nat-pmp lease; the timer renews well inside it
  protonLeaseS = 60;

  nuScript =
    name: deps:
    pkgs.writers.writeNu name {
      makeWrapperArgs = [
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath deps)
      ];
    } ./lib/${name}.nu;
  protonvpnPort = nuScript "protonvpn-port" [
    pkgs.libnatpmp
    pkgs.nftables
    pkgs.curl
  ];
  publicAddress = nuScript "public-address" [
    pkgs.curl
    pkgs.coreutils
  ];
  ddnsCloudflare = nuScript "ddns-cloudflare" [
    pkgs.curl
    pkgs.coreutils
  ];

  torPorts = import ../../../modules/tor-ports.nix;
  torFlowsOn = port: lib.filter (f: lib.elem port (f.tcp or [ ])) flows.router;
  # who flows.nix lets reach a tor listener: socks and the transparent port alike are tor's SocksPolicy
  torClients = lib.concatMap (f: addressesOf f.from) (torFlowsOn torPorts.socksIsolated ++ torFlowsOn torPorts.trans);
  # a redirect lands on the address of the interface it came in by: the router's own in each zone with members
  torTransAddresses = map (f: zones.${f.from.network}.routerIp) (torFlowsOn torPorts.trans);
  torDnsAddress = "127.0.0.1";
  torCookie = "/var/lib/tor/control_auth_cookie";
  torControlTimeoutS = 5;
  torControl = pkgs.writeShellScript "tor-control" ''
    set -euo pipefail
    cookie=$(${pkgs.xxd}/bin/xxd -p -c 256 ${torCookie})
    printf 'AUTHENTICATE %s\r\n%s\r\nQUIT\r\n' "$cookie" "$1" | ${pkgs.netcat-gnu}/bin/nc -w ${toString torControlTimeoutS} 127.0.0.1 ${toString torPorts.control}
  '';
  torTextfile = "tor";

  ingressIp = zone: net.ipOf zones.${zone}.ingress;
  hostsOf = side: lib.unique (map (r: r.host) (lib.attrValues catalog.${side}));
  internalExtraHosts = lib.attrValues net.ingressPages;
  # the edge answers these itself
  installHosts = lib.attrNames (import ../../../modules/install-hosts.nix);
  forwardHosts = lib.filter (h: h != null) (map (f: f.host) flows.portForwards);
  # names that skip the ingresses; a wildcard host has no single address for a hosts line, the templates answer it
  directHosts = {
    smb = net.ipOf lab.roles.nas;
  }
  // lib.mapAttrs' (_: r: lib.nameValuePair r.host (net.ipOf (toString r.vmid))) (
    lib.filterAttrs (_: r: r.vmid != null && r.publicPort == null && !(service.wildcardHost r.host)) catalog.l4
  );

  # install lines, the wireguard endpoint and port forwards cannot pass cloudflare's proxy; a wildcard forward is the
  # record `*.<rest>.<domain>`, which cloudflare accepts below the apex
  routeHosts =
    side:
    map (r: {
      inherit (r) host;
      proxied = lib.elem "cloudflare" r.on;
    }) (lib.filter service.publicOf (lib.attrValues catalog.${side}));
  allRouteHosts =
    routeHosts "internal"
    ++ routeHosts "external"
    ++ map (host: {
      inherit host;
      proxied = true;
    }) internalExtraHosts;
  proxiedHosts = lib.unique (map (r: r.host) (lib.filter (r: r.proxied) allRouteHosts));
  rawHosts = lib.subtractLists proxiedHosts (
    lib.unique (
      map (r: r.host) (lib.filter (r: !r.proxied) allRouteHosts) ++ installHosts ++ forwardHosts ++ [ net.wan.publicHost ]
    )
  );
  ddnsRecords = pkgs.writeText "ddns-records.json" (
    builtins.toJSON (
      map (h: {
        name = net.fqdn h;
        proxied = true;
      }) proxiedHosts
      ++ map (h: {
        name = net.fqdn h;
        proxied = false;
      }) rawHosts
    )
  );

  hostLines = ip: names: lib.concatMapStrings (h: "      ${ip} ${net.fqdn h}\n") names;
  # the forwards a name leads to: inside the lab it resolves straight to the backend
  hostForwards = lib.filter (f: f.host != null) flows.portForwards;
  # a name's tcp and udp forwards (teamspeak's voice and files) share its guest: one line per name and backend
  forwardHostLines = lib.unique (
    lib.concatMap (f: map (ip: hostLines ip [ f.host ]) f.addresses) (
      lib.filter (f: !(service.wildcardHost f.host)) hostForwards
    )
  );
  wildcardZones = map (host: rec {
    zone = net.fqdn (lib.removePrefix "*." host);
    match = "^[a-z0-9-]+\\.${lib.replaceStrings [ "." ] [ "\\." ] zone}\\.$";
    addresses = lib.unique (lib.concatMap (f: f.addresses) (lib.filter (f: f.host == host) hostForwards));
  }) (lib.unique (map (f: f.host) (lib.filter (f: service.wildcardHost f.host) hostForwards)));

  publicAddressFile = "/run/public-address/hosts";
  publicPrefixFile = "/run/public-address/prefix6";
  fritzboxUpnpUrl = "http://${net.wan.gateway}:${toString ports.fritzboxUpnp}/igdupnp/control/WANIPConn1";
  # an answer coredns keeps serving while every upstream is down
  dnsStaleS = 86400;

  # on disk: a restart during an outage keeps the last lists
  blocklistDir = "/var/lib/blocklists";
  blocklists = {
    stevenblack = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
    # hagezi dropped its hosts format; blocky reads the wildcard one (*.domain)
    hagezi-pro = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.txt";
  };
  blocklistTimeoutS = 120;

  blockyAddress = "127.0.0.1:5335";
  blockyUpstream = "tcp-tls:1.1.1.1:853";
  # dns over tls when blocky is down: a fallback, but never a plaintext one
  dnsFallback = {
    servers = [
      "tls://1.1.1.1"
      "tls://1.0.0.1"
    ];
    name = "cloudflare-dns.com";
  };
  # an egress class's members resolve through its exit and fail with it, so no name they look up leaves through the house
  viewOf = members: lib.concatMapStringsSep " || " (ip: "incidr(client_ip(), '${ip}/32')") members;

  # per internet source: far above a browser's kept-alive handful, far below a flood
  wanSynPerSecond = 50;
  wanSynBurst = 100;
  wanConnsMax = 200;
  # a quarter of nf_conntrack_max
  wanMeterSize = 65535;
  # the source the fritzbox's hairpin gives a house client calling a public name; the fritzbox drops the internet's
  # packets claiming it
  houseAddressSet = "house_public";
  # a reload empties the set
  houseAddressFill = pkgs.writeShellScript "wan-limits-house" ''
    set -euo pipefail
    ip=$(${pkgs.coreutils}/bin/cut -d ' ' -f 1 ${publicAddressFile})
    ${pkgs.nftables}/bin/nft flush set ip wan-limits ${houseAddressSet}
    if [ -n "$ip" ]; then ${pkgs.nftables}/bin/nft add element ip wan-limits ${houseAddressSet} "{ $ip }"; fi
  '';
  # over every client of one forward: a game server's players and a flood's leftovers alike
  forwardConnsMax = 256;
  # bounds the journal under a flood
  forwardLogPerMinute = 60;
  # the wan and, hairpinned, the trusted networks; never a dmz
  forwardSources = set (
    map (n: "\"${n.interface}\"") (
      lib.attrValues (lib.filterAttrs (name: n: name == "lan" || n.reaches == "everything") flows.networks)
    )
  );
  conntrackMax = 262144;
  # a forward to several guests (an app's nodes) keeps each client on one of them
  dnatTarget =
    f:
    if lib.length f.addresses == 1 then
      "${lib.head f.addresses}:${toString f.targetPort}"
    else
      "jhash ip saddr mod ${toString (lib.length f.addresses)} map { "
      + lib.concatStringsSep ", " (lib.imap0 (i: ip: "${toString i} : ${ip}") f.addresses)
      + " } : ${toString f.targetPort}";

  dhcpUnaddressed = "0.0.0.0";
in
{
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

  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.useDHCP = false;
  networking.interfaces = {
    ${wan}.ipv4.addresses = [
      {
        inherit (net.wan) address;
        prefixLength = lib.toInt (lib.last (lib.splitString "/" net.wan.subnet));
      }
    ];
  }
  // lib.mapAttrs' (
    _: z:
    lib.nameValuePair z.interface {
      ipv4.addresses = [
        {
          address = z.routerIp;
          prefixLength = z.prefix;
        }
      ];
    }
  ) zones;
  networking.defaultGateway = {
    address = net.wan.gateway;
    interface = wan;
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_max_syn_backlog" = 4096;
    "net.ipv4.tcp_synack_retries" = 2;
    # loose: strict drops every vpn reply; sources are bound to interfaces by table antispoof instead
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    "net.netfilter.nf_conntrack_max" = conntrackMax;
  };

  # a source arrives only on the interface it belongs to, before routing, input or forward see it
  networking.nftables.tables.antispoof = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority raw; policy accept;
        ip saddr ${dhcpUnaddressed} udp dport ${toString ports.dhcpServer} return
    ''
    + lib.concatMapStrings (n: ''
      iifname "${n.interface}" ip saddr != ${set n.sources} counter drop
    '') labNetworks
    + ''
        # the wan carries the internet and the house, never a lab address
        iifname "${wan}" ip saddr ${set (lib.concatMap (n: n.sources) labNetworks)} counter drop
      }
    '';
  };

  networking.nftables.tables.egress = lib.mkIf (vpnMembers != [ ] || torMembers != [ ]) {
    family = "ip";
    content =
      lib.optionalString (vpnMembers != [ ]) ''
        chain premark {
          type filter hook prerouting priority mangle; policy accept;
          # never divert lab or house traffic: replies to them would blackhole
          ip daddr ${privateRanges} return
          ip saddr ${set vpnMembers} meta mark set ${toString egressMarks.vpn.mark}
        }
        # the tunnel's mtu is below the zones' 1500 and icmp too-big rarely makes it back through the provider
        chain mssclamp {
          type filter hook forward priority mangle; policy accept;
          oifname "${vpnInterface}" tcp flags syn tcp option maxseg size set rt mtu
        }
      ''
      + lib.optionalString (torMembers != [ ]) ''
        chain torredirect {
          type nat hook prerouting priority dstnat; policy accept;
          ip saddr ${set torMembers} ip daddr != ${privateRanges} meta l4proto tcp counter redirect to :${toString torPorts.trans}
        }
      ''
      + ''
        # stateless, ahead of nixos-fw: a lost rule or route must never leak through the house
        chain killswitch {
          type filter hook forward priority filter - 5; policy accept;
      ''
      + lib.optionalString (vpnMembers != [ ]) ''
        ip saddr ${set vpnMembers} oifname "${wan}" ip daddr != ${privateRanges} counter drop
      ''
      + lib.optionalString (torMembers != [ ]) ''
        # through no interface: what tor carries never reaches forward, the rest has no exit
        ip saddr ${set torMembers} ip daddr != ${privateRanges} counter drop
      ''
      + ''
        }
      '';
  };

  systemd.services.egress-policy = lib.mkIf (vpnMembers != [ ]) {
    description = "Policy routing for the VPN egress class";
    after = [ "network-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 5;
    };
    script = ''
      set -euo pipefail
      table=${toString egressMarks.vpn.table}
      # ip rule has no replace
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

  homelab.egress.vpn = {
    enable = true;
    inherit (egressMarks.vpn) table;
    # clients cannot share a key
    privateKeyFile = config.sops.secrets.protonvpn-private-key.path;
    address = "10.2.0.2/32";
    # CH#684; an address: dns is in the tunnel
    servers = [
      {
        publicKey = "36G8+pInNcPK9F1TpHglWs9Pk5uJOY9o8SCNrCBgvHE=";
        endpoint = "89.222.96.158:51820";
      }
    ];
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
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "protonvpn";
      ExecStart = "${protonvpnPort}";
    };
    environment = {
      PEER_HOST = vpnInboundIp;
      GATEWAY = vpnCfg.gateway;
      LEASE_S = toString protonLeaseS;
    };
  };
  systemd.timers.protonvpn-port = lib.mkIf (vpnInbound != [ ]) {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "90s";
      OnUnitActiveSec = "45s";
      AccuracySec = "5s";
    };
  };

  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;
    client = {
      enable = true;
      # the owner's check from the router itself (hermes skill downloads); the firewall opens it to nobody
      socksListenAddress = {
        addr = zones.internal.routerIp;
        port = torPorts.socks;
      };
    };
    settings = {
      SocksPolicy =
        map (ip: "accept ${ip}") (
          torClients
          ++ [
            zones.internal.routerIp
            torDnsAddress
          ]
        )
        ++ [ "reject *" ];
      # one circuit per indexer: no exit sees two of them from one client
      SOCKSPort = [
        {
          addr = zones.internal.routerIp;
          port = torPorts.socksIsolated;
          IsolateDestAddr = true;
          IsolateDestPort = true;
        }
      ];
      TransPort = map (addr: {
        inherit addr;
        port = torPorts.trans;
      }) torTransAddresses;
      DNSPort = lib.optional (torMembers != [ ]) {
        addr = torDnsAddress;
        port = torPorts.dns;
      };
      ClientUseIPv6 = false;
      MaxCircuitDirtiness = 600;
      NewCircuitPeriod = 120;
      CircuitBuildTimeout = 30;
      ControlPort = [
        {
          addr = "127.0.0.1";
          port = torPorts.control;
        }
      ];
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
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "30m";
      RandomizedDelaySec = "10m";
    };
  };

  # tor down or without a circuit: the gauge says 0, never its last 1
  homelab.textfiles = [
    torTextfile
    forwardDenyTextfile
  ];
  systemd.services.tor-status = {
    description = "Publish whether tor has a circuit";
    after = [ "tor.service" ];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
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
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "5m";
    };
  };

  # flows.nix `router` opens every port, per network and source
  services.openssh.openFirewall = false;
  services.prometheus.exporters.node.openFirewall = false;

  networking.nat = {
    enable = true;
    externalInterface = wan;
    internalInterfaces = map (n: n.interface) labNetworks;
    # nixos forwardPorts would match all wan traffic
    forwardPorts = [ ];
  };
  # proxmox routes the lab back through the router (pve-install.nu), so its firewall tells the guests apart instead of
  # seeing every one of them as the router; ahead of nixos nat's masquerade in the same chain
  networking.nftables.tables.nixos-nat.content = lib.mkBefore ''
    chain post {
      type nat hook postrouting priority srcnat;
      oifname "${wan}" ip daddr ${net.wan.proxmox} return
    }
  '';

  networking.nftables.enable = true;
  # named before the forward rules that count into them
  networking.nftables.tables.nixos-fw.content = lib.mkBefore (
    lib.concatMapStrings (network: "counter ${denyCounterOf network} { }\n") denyingNetworks
  );
  systemd.services.forward-deny-textfile = {
    description = "Publish the forwards refused between the networks";
    path = [
      pkgs.nftables
      pkgs.jq
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      metrics=${config.homelab.textfileDir}/${forwardDenyTextfile}.prom
      {
        printf '# TYPE homelab_forward_denied_packets_total counter\n'
        nft -j list counters table inet nixos-fw | jq -r '
          .nftables[].counter // empty | select(.name | startswith("fwd-deny-"))
          | "homelab_forward_denied_packets_total{network=\"\(.name | ltrimstr("fwd-deny-"))\"} \(.packets)"'
      } > "$metrics.tmp"
      mv "$metrics.tmp" "$metrics"
    '';
  };
  systemd.timers.forward-deny-textfile = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1m";
      OnUnitActiveSec = "1m";
    };
  };
  # nixos' stop deletes every table while forwarding stays on; start replaces them in one transaction anyway
  systemd.services.nftables.serviceConfig.ExecStop = lib.mkForce [ ];
  networking.firewall = {
    checkReversePath = "loose";
    enable = true;
    filterForward = true;
    extraInputRules = inputRules;
    # ahead of the nat module's own accepts, which would otherwise let a dmz reach the house
    extraForwardRules = lib.mkBefore forwardRules;
  };

  # per internet source, ahead of every accept and dnat; exempt: the house lan, by its own address or hairpinned through
  # its public one, and cloudflare (the edge limits it)
  networking.nftables.tables.wan-limits = {
    family = "ip";
    content = ''
      set ${houseAddressSet} {
        type ipv4_addr;
      }
      chain prerouting {
        type filter hook prerouting priority filter - 1; policy accept;
        ip saddr ${set [ net.wan.subnet ]} return
        ip saddr @${houseAddressSet} return
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
  # refilled whenever the ruleset is loaded or the address is learned; "-": a failed fill never fails the firewall
  systemd.services.nftables.serviceConfig = {
    ExecStartPost = lib.mkAfter [ "-${houseAddressFill}" ];
    ExecReload = lib.mkAfter [ "-${houseAddressFill}" ];
  };
  systemd.services.wan-limits-house = {
    description = "Exempt the house's public address from the wan limits";
    after = [ "nftables.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = houseAddressFill;
    };
  };
  systemd.paths.wan-limits-house = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathChanged = publicAddressFile;
  };

  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
    ''
    + lib.concatMapStrings (
      f:
      let
        match = "iifname ${forwardSources} ip daddr ${net.wan.address} ${f.proto} dport ${toString f.port}";
      in
      ''
        # ${f.why}
      ''
      + lib.optionalString (lib.elem "inflightLimit" f.on) ''
        ${match} ct state new ct count over ${toString forwardConnsMax} counter drop
      ''
      + lib.optionalString (lib.elem "accessLog" f.on) ''
        ${match} ct state new limit rate ${toString forwardLogPerMinute}/minute log prefix "dnat ${toString f.port}: " level info
      ''
      + ''
        ${match} dnat to ${dnatTarget f}
      ''
    ) flows.portForwards
    + ''
      }
    '';
  };

  # never on a guest's static address (lib.tf invariants)
  services.kea.dhcp4 =
    let
      pooled = lib.filter (z: z.dhcpPool != null) (lib.attrValues zones);
    in
    {
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
          pools = [ { pool = "${z.dhcpPool.first} - ${z.dhcpPool.last}"; } ];
          option-data = [
            {
              name = "routers";
              data = z.routerIp;
            }
            {
              name = "domain-name-servers";
              data = z.routerIp;
            }
          ];
        }) pooled;
      };
    };

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
        {
          upstream = blockyUpstream;
          ips = [ "1.1.1.1" ];
        }
      ];
      blocking = {
        denylists.ads = map (name: "${blocklistDir}/${name}") (lib.attrNames blocklists);
        clientGroupsBlock.default = [ "ads" ];
      };
      caching = {
        minTime = "5m";
        maxTime = "30m";
        prefetching = true;
      };
      # a line per query was most of the router's journal
      queryLog.type = "none";
    };
  };

  services.resolved.enable = false;
  # coredns, explicit rather than glibc's fallback
  networking.nameservers = [ "127.0.0.1" ];
  services.coredns = {
    enable = true;
    config = ''
      ${net.domain}:53 {
        hosts ${publicAddressFile} {
    ''
    + hostLines (ingressIp "internal") (hostsOf "internal" ++ internalExtraHosts)
    + ""
    + hostLines (ingressIp "external") (hostsOf "external" ++ installHosts)
    + ""
    + lib.concatStrings (lib.mapAttrsToList (h: ip: hostLines ip [ h ]) directHosts)
    + lib.concatStrings forwardHostLines
    + ''
        fallthrough
      }
    ''
    + lib.concatMapStrings (f: ''
      template IN SRV ${f.srv}.${net.fqdn f.host} {
        answer "{{ .Name }} 3600 IN SRV 0 0 ${toString f.port} ${net.fqdn f.host}."
      }
    '') (lib.filter (f: f.srv != null) hostForwards)
    + lib.concatMapStrings (w: ''
      # every name one label below a wildcard forward, straight to its backend; coredns runs template before hosts,
      # so the zone stays this one and falls through to the lines above
      template IN A ${w.zone} {
        match ${w.match}
        ${lib.concatStringsSep "\n          " (map (ip: ''answer "{{ .Name }} 3600 IN A ${ip}"'') w.addresses)}
        fallthrough
      }
      # the nodata the hosts plugin gives an exact name, instead of asking blocky for a name only the lab knows
      template IN AAAA ${w.zone} {
        match ${w.match}
        fallthrough
      }
    '') wildcardZones
    + ''
        # mx, txt and public-only records
        forward . ${blockyAddress}
      }

      # the house's ipv6 prefix, a zone of its own: the lab domain's hosts file is the v4 address's alone
      ${net.fqdn net.wan.publicPrefixHost}:53 {
        hosts ${publicPrefixFile}
      }
    ''
    + lib.optionalString (vpnMembers != [ ]) ''

      .:53 {
        view vpn {
          expr ${viewOf vpnMembers}
        }
        forward . ${vpnCfg.dns}
        cache 300
      }
    ''
    + lib.optionalString (torMembers != [ ]) ''

      .:53 {
        view tor {
          expr ${viewOf torMembers}
        }
        forward . ${torDnsAddress}:${toString torPorts.dns}
      }
    ''
    + ''

      .:53 {
        # dns survives blocky, encrypted
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

  sops.secrets.wireguard-private-key = { };
  sops.secrets.cloudflare-token = { };

  systemd.tmpfiles.rules = [
    "d ${dirOf publicAddressFile} 0755 root root -"
    "f ${publicAddressFile} 0644 root root -"
    "f ${publicPrefixFile} 0644 root root -"
    "d ${blocklistDir} 0755 root root -"
  ];
  systemd.services.public-address = {
    description = "Learn the house's public address";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onSuccess = [ "ddns-cloudflare.service" ];
    environment = {
      PUBLIC_URL = fritzboxUpnpUrl;
      PUBLIC_FILE = publicAddressFile;
      PUBLIC_HOST = net.fqdn net.wan.publicHost;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${publicAddress} v4";
    };
  };
  systemd.timers.public-address = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services.public-prefix = {
    description = "Learn the house's public ipv6 prefix";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      PUBLIC_URL = fritzboxUpnpUrl;
      PUBLIC_FILE = publicPrefixFile;
      PUBLIC_HOST = net.fqdn net.wan.publicPrefixHost;
      PUBLIC_PREFIX_LENGTH = toString net.wan.publicPrefixLength;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${publicAddress} prefix6";
    };
  };
  systemd.timers.public-prefix = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services.ddns-cloudflare = {
    description = "Point the ${net.domain} A records at the current public IP";
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
    script = "exec ${upstream.run} cloudflare ${ddnsCloudflare}";
  };

  systemd.services.blocklists-fetch = {
    description = "Fetch blocky's deny lists";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.coreutils
      pkgs.diffutils
      pkgs.systemd
    ];
    serviceConfig = {
      Type = "oneshot";
      SuccessExitStatus = [ upstream.unavailable ];
    };
    script = ''
      status=0
      changed=0
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
    timerConfig = {
      OnBootSec = "2min";
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };

  # clients need DNS = 10.0.0.1
  networking.wireguard.interfaces.wg0 = {
    ips = [ "${net.wireguard.address}/${toString net.wireguard.prefix}" ];
    listenPort = ports.wireguard;
    privateKeyFile = config.sops.secrets.wireguard-private-key.path;
    peers = [
      {
        # laptop
        publicKey = "uS6fCRVw/IvsfT4R7r0coMLxWl9+gHRY0H/KlNFkBVs=";
        allowedIPs = [ "10.0.0.2/32" ];
      }
      {
        # phone
        publicKey = "lplUjlL/gPLRaSwi/wbtmpZ34BCinSq9bY9dmwxXh3s=";
        allowedIPs = [ "10.0.0.3/32" ];
      }
      {
        # tablet
        publicKey = "AW4t+4glZqmUl8ZAtrq60K/GTDmzZJisz1+6EqYnmzI=";
        allowedIPs = [ "10.0.0.4/32" ];
      }
      {
        # pc, config in secrets repo wg0.pc.conf
        publicKey = "rvtqHdSDK3JGZhZkzVYIcb9gKHiZUTsenfpJtm4adT0=";
        allowedIPs = [ "10.0.0.5/32" ];
      }
    ];
  };

  # wol-pc wakes luca-pc from the vpn; its mac is a device identity, kept out of the public repo
  sops.secrets.workstation-mac = { };
  # a command, not a shell alias: `ssh <router> wol-pc` runs no profile
  environment.systemPackages = with pkgs; [
    tcpdump
    iperf3
    wireguard-tools
    ethtool
    (writeShellApplication {
      name = "wol-pc";
      runtimeInputs = [ wakeonlan ];
      text = "wakeonlan \"$(cat ${config.sops.secrets.workstation-mac.path})\"";
    })
  ];
}
