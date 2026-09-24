{ config, pkgs, lib, inventory, ... }:
let
  routes = import ../modules/routes.nix;

  # ── egress classes (modules/egress.nix) ────────────────────────────────────
  # Policy routing, keyed on source address. A member VM is untouched: it keeps
  # its ordinary default route here, and this decides what happens next.
  egress = import ../modules/egress.nix;
  # The VPN exit is a routing decision, so it needs a mark and a table. Tor
  # is not: Tor runs on this router, so a member is redirected into it.
  torPorts = { trans = 9040; dns = 9053; socks = 9050; socksIsolated = 9055; };
  # fwmark -> routing table. Marks are set in the mangle hook below and matched
  # by `ip rule`; the tables hold nothing but a default route each.
  egressMarks = { vpn = { mark = 1; table = 100; }; };
  membersOf = via: lib.sort (a: b: a < b)
    (lib.mapAttrsToList (_: e: inventory.${toString e.vmid}.ip)
      (lib.filterAttrs (_: e: e.via == via && inventory ? ${toString e.vmid}) egress));
  vpnMembers = membersOf "vpn";
  torMembers = membersOf "tor";
  torSet = lib.concatStringsSep ", " torMembers;
  # nftables rejects an empty set literal, so each rule is emitted only when it
  # has members.
  markRule = via: members:
    lib.optionalString (members != [ ])
      "ip saddr { ${lib.concatStringsSep ", " members} } meta mark set ${toString egressMarks.${via}.mark}";
  vpnCfg = config.homelab.egress.vpn;
  # the one member that takes unsolicited inbound connections through the exit.
  peerHost = inventory."112".ip;
  hostsOf = side: lib.unique (map (r: r.host) (lib.attrValues routes.${side}));
  # hosts served by internal Traefik that are not a VM route.
  internalExtraHosts = [ "traefik" "proxmox" ];

  # Whether a host is Cloudflare-PROXIED comes from `proxied` in routes.nix, so
  # the ingress policy lives next to the route rather than in a list here.
  #
  #   proxied   Authelia stands in front, so the edge's DDoS absorption is worth
  #             having and the rotating edge address costs nothing: Traefik only
  #             needs the Host header to route, and Authelia only needs a cookie.
  #   DNS-only  public by design and defended by Anubis. Behind the edge Anubis
  #             sees a different Cloudflare address on every request and issues a
  #             fresh challenge each time, so the proof-of-work never sticks.
  #             Going direct is what makes it work at all.
  #
  # Concealing the origin is not a consideration either way: the DNS-only
  # wildcard below already answers every unlisted name with the WAN address.
  routeHosts = side: lib.mapAttrsToList (_: r: {
    inherit (r) host;
    proxied = r.proxied or true;
  }) routes.${side};
  allRouteHosts = routeHosts "internal" ++ routeHosts "external"
    ++ map (h: { host = h; proxied = true; }) internalExtraHosts;

  proxiedHosts = lib.unique (map (r: r.host) (lib.filter (r: r.proxied) allRouteHosts));
  # unproxied (raw WAN IP): the Anubis-fronted routes, the L4 services Cloudflare
  # cannot proxy, plus a DNS-only wildcard kept fresh so no unlisted name goes
  # stale.
  rawHosts = lib.unique (
    map (r: r.host) (lib.filter (r: !r.proxied) allRouteHosts)
    ++ [ "wg" "mc" "tor" "*" ]
  );
  # domain:proxied entries the DDNS loop consumes.
  ddnsDomains = lib.concatStringsSep " " (
    (map (h: "${h}.lsck0.dev:true") proxiedHosts)
    ++ (map (h: "${h}.lsck0.dev:false") rawHosts)
  );
in {
  networking.hostName = "luca-router";

  # mDNS on ens18 only, so the FritzBox shows "luca-router" (ens18 is static, so
  # it never sends a DHCP hostname and otherwise shows the install-time "nixos").
  services.avahi = {
    enable = true;
    allowInterfaces = [ "ens18" ];
    ipv4 = true;
    ipv6 = false;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      hinfo = true;
    };
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # NETWORK INTERFACES
  # ─────────────────────────────────────────────────────────────────────────────
  # ens18 = WAN    -> static lease from FritzBox
  # ens19 = Internal LAN  (10.100.0.0/24)
  # ens20 = External DMZ  (10.200.0.0/24)
  # wg0   = WireGuard VPN (10.0.0.0/24)

  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{ address = "192.168.178.29"; prefixLength = 24; }];
  networking.defaultGateway = { address = "192.168.178.1"; interface = "ens18"; };
  networking.interfaces.ens19.ipv4.addresses = [{ address = "10.100.0.1"; prefixLength = 24; }];
  networking.interfaces.ens20.ipv4.addresses = [{ address = "10.200.0.1"; prefixLength = 24; }];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;

    # ── volumetric / spoofing hardening on the edge ──────────────────────────
    # SYN cookies answer a SYN flood without keeping half-open state, so the
    # backlog cannot be exhausted; the larger backlog and fewer SYN-ACK retries
    # shorten how long a half-open entry occupies it.
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_max_syn_backlog" = 4096;
    "net.ipv4.tcp_synack_retries" = 2;
    # loose reverse-path filter: drop packets whose source address has no route
    # at all. Loose (2) rather than strict (1) on purpose - strict mode drops
    # legitimate traffic as soon as routing is asymmetric, which is easy to hit
    # with WireGuard.
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    # no source routing, no redirects: both let a remote host steer traffic.
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    # do not be an amplifier.
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    "net.ipv4.icmp_ignore_bogus_error_responses" = 1;
    # headroom so a flood fills the conntrack table more slowly than it fills
    # the per-source meters below.
    "net.netfilter.nf_conntrack_max" = 262144;
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # EGRESS CLASSES
  # ─────────────────────────────────────────────────────────────────────────────
  # A VM listed in modules/egress.nix leaves through something other than the
  # WAN NAT. Its packets are marked by source address, and the mark selects a
  # routing table holding one default route.
  #
  # The killswitch is the same idea modules/vpn.nix used: each table ends in a
  # blackhole, so when the exit is down there is nowhere for a member's packets
  # to go. They are never allowed to fall back to the main table, which is what
  # "leaving through the house" would mean.
  assertions = [{
    assertion = vpnMembers == [ ] || vpnCfg.enable;
    message = "modules/egress.nix routes ${lib.concatStringsSep ", " vpnMembers} through the VPN, but homelab.egress.vpn is not enabled on the router.";
  }];

  networking.nftables.tables.egress = lib.mkIf (vpnMembers != [ ] || torMembers != [ ]) {
    family = "ip";
    content = ''
      chain premark {
        type filter hook prerouting priority mangle; policy accept;
        # The lab and the house are never diverted. Without this a member's
        # reply to an ssh session from the house is marked like anything else,
        # looked up in a table whose only entries are the tunnel and a
        # blackhole, and dropped - the VM answers on no address at all.
        #
        # modules/vpn.nix needed the same exception and called it lanRoutes,
        # kept by hand per VM. Getting that list wrong took vm-112 off the
        # network once already; here it is one rule for every member.
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
        ${markRule "vpn" vpnMembers}
      }
      ${lib.optionalString (torMembers != [ ]) ''
        chain tor-redirect {
          type nat hook prerouting priority dstnat - 3; policy accept;
          # same exception as the mark chain: Tor is for leaving the house, not
          # for reaching the NAS. A redirect of lab-local traffic would send it
          # to an exit node that cannot route 10.0.0.0/8 anywhere.
          ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } return
          # DNS first: a name has to become one of Tor's virtual addresses
          # before redirecting a TCP connection to it means anything.
          ip saddr { ${torSet} } udp dport 53 redirect to :${toString torPorts.dns}
          ip saddr { ${torSet} } tcp dport 53 redirect to :${toString torPorts.dns}
          ip saddr { ${torSet} } tcp flags & (fin|syn|rst|ack) == syn redirect to :${toString torPorts.trans}
        }
        chain tor-drop {
          type filter hook forward priority filter - 5; policy accept;
          # Whatever is still being forwarded from a tor member is UDP that is
          # not DNS - QUIC, NTP, trackers - because every TCP connection and
          # every lookup was redirected above and is handled locally. Tor
          # cannot carry it, and letting it take the WAN NAT would publish the
          # house address for exactly the traffic nobody thinks to check.
          ip saddr { ${torSet} } ct state established,related accept
          ip saddr { ${torSet} } counter drop
        }
      ''}
    '';
  };

  # The VPN exit needs policy routing; Tor does not, because it runs here.
  # Idempotent, so a redeploy does not stack duplicate rules, and a oneshot so
  # it can be re-run by hand.
  systemd.services.egress-policy = lib.mkIf (vpnMembers != [ ]) {
    description = "Policy routing for the VPN egress class";
    after = [ "network-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -eu
      ip rule del fwmark ${toString egressMarks.vpn.mark} table ${toString egressMarks.vpn.table} 2>/dev/null || true
      ip rule add fwmark ${toString egressMarks.vpn.mark} table ${toString egressMarks.vpn.table} priority 101
      # the floor of the table: when the tunnel is down there is nowhere for a
      # member's packets to go, rather than a quiet fall back to the house.
      ip route replace blackhole default metric 1000 table ${toString egressMarks.vpn.table}

      # The lab's own subnets, so reverse-path filtering passes. rpfilter
      # validates a packet's source against the table its mark selects, and a
      # table holding only the tunnel makes 10.100.0.112 look as though it
      # arrived from wg-egress rather than from ens19 - so every marked packet
      # was dropped in `rpfilter-allow` before it ever reached the tunnel.
      #
      # This does not weaken the killswitch: the default route here is still
      # the tunnel and then a blackhole. These entries only describe where the
      # lab's own addresses legitimately live.
      ip route replace 10.100.0.0/24 dev ens19 table ${toString egressMarks.vpn.table}
      ip route replace 10.200.0.0/24 dev ens20 table ${toString egressMarks.vpn.table}
      ip route replace 192.168.178.0/24 dev ens18 table ${toString egressMarks.vpn.table}
    '';
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # TOR EXIT
  # ─────────────────────────────────────────────────────────────────────────────
  # The other half of the proxy. Was vm-113, a VM whose whole job was to hold a
  # Tor client and forward for others; with the exits collected here there is
  # nothing left for it to do, and running Tor on the router is what makes the
  # transparent path simple: a redirect has to happen where Tor runs, because
  # TransPort recovers the address the client meant to reach with
  # SO_ORIGINAL_DST, and that is only recorded where the translation happened.
  # On a separate VM that forced the router to route to it as a next hop and to
  # punch a hole in the DMZ isolation. Here it is one redirect.
  #
  # Client only. This relays nothing for anyone - the public non-exit relay is
  # vm-202, which is a different thing entirely.
  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;
    client = {
      enable = true;
      socksListenAddress = {
        addr = "10.100.0.1";
        port = torPorts.socks;
        # A torrent client opens connections to hundreds of peers at once and
        # would build a circuit for each. Shared circuits on this port.
        IsolateDestAddr = false;
      };
    };
    settings = {
      # the lab, both sides. The DMZ can use it now as well: the proxy is the
      # router, so a DMZ VM reaches it without crossing into the internal LAN.
      SocksPolicy = [ "accept 10.100.0.0/24" "accept 10.200.0.0/24" "reject *" ];

      # Second SOCKS port for the indexers (Prowlarr). Indexer traffic is a
      # handful of requests to a handful of sites, so it gets real stream
      # isolation: a separate circuit per destination, and a separate circuit
      # from anything on the shared port.
      SOCKSPort = [{
        addr = "10.100.0.1";
        port = torPorts.socksIsolated;
        IsolateDestAddr = true;
        IsolateDestPort = true;
      }];

      # The transparent pair, for whole VMs listed via = "tor" in
      # modules/egress.nix. Those VMs have no Tor configuration at all.
      TransPort = [{ addr = "10.100.0.1"; port = torPorts.trans; }];
      DNSPort = [{ addr = "10.100.0.1"; port = torPorts.dns; }];
      AutomapHostsOnResolve = true;
      # keeps DNSPort's mapped answers resolvable by TransPort, which is what
      # makes name-based connections work at all.
      VirtualAddrNetworkIPv4 = "10.192.0.0/10";
      ClientUseIPv6 = false;

      # Path rotation. Tor picks a new guard rarely by design - rotating guards
      # is what deanonymises you - but the middle and exit relays turn over:
      #   MaxCircuitDirtiness  a circuit stops taking new streams after 10 min
      #   NewCircuitPeriod     consider building a fresh circuit every 2 min
      MaxCircuitDirtiness = 600;
      NewCircuitPeriod = 120;
      CircuitBuildTimeout = 30;

      ControlPort = [{ addr = "127.0.0.1"; port = 9051; }];
      CookieAuthentication = true;
    };
  };

  # MaxCircuitDirtiness only stops *new* streams reusing an old circuit. NEWNYM
  # retires the ones already in use, so a long session does not sit on the same
  # three relays for days.
  systemd.services.tor-new-circuits = {
    description = "Ask Tor for a fresh set of circuits";
    after = [ "tor.service" ];
    requires = [ "tor.service" ];
    path = [ pkgs.coreutils pkgs.netcat-gnu pkgs.xxd ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
      printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" | nc -w 5 127.0.0.1 9051
    '';
  };
  systemd.timers.tor-new-circuits = {
    wantedBy = [ "timers.target" ];
    # randomised so the rotation is not itself a clock-like fingerprint.
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "30m"; RandomizedDelaySec = "10m"; };
  };

  # The VPN exit itself is modules/egress-vpn.nix: it owns the tunnel and the
  # default route in table 100. On the router rather than a VM of its own,
  # because it needs nothing from the host it runs on and a dedicated gateway
  # would cost memory the lab does not have. Tor is the other way round, for
  # the SO_ORIGINAL_DST reason above, so the two exits are deliberately
  # asymmetric.
  homelab.egress.vpn = {
    enable = true;
    table = egressMarks.vpn.table;
    # The key vm-112 used to hold. Moved here rather than duplicated: two
    # WireGuard clients cannot share a key and an address, so the VM having
    # given it up is what makes this work. The VM now has no tunnel at all.
    privateKeyFile = config.sops.secrets.protonvpn-private-key.path;
    address = "10.2.0.2/32";
    publicKey = "36G8+pInNcPK9F1TpHglWs9Pk5uJOY9o8SCNrCBgvHE=";
    # CH#684. An address and not a name, because DNS is inside the tunnel.
    endpoint = "89.222.96.158:51820";
  };
  sops.secrets.protonvpn-private-key = { };

  # ── Proton's forwarded port ────────────────────────────────────────────────
  # One tunnel gets one port, so the router leases it and forwards it to the
  # one member that needs unsolicited inbound connections. Everything else
  # behind the exit is ordinary outbound NAT and needs nothing here.
  #
  # The port changes whenever the 60-second lease lapses, so the DNAT cannot be
  # written once. It matches a named set instead, and the renewal unit replaces
  # the set's single element.
  networking.nftables.tables.proton-port = {
    family = "ip";
    content = ''
      set proton_port {
        type inet_service;
      }
      chain prerouting {
        type nat hook prerouting priority dstnat - 2; policy accept;
        iifname "wg-egress" tcp dport @proton_port dnat to ${peerHost}
        iifname "wg-egress" udp dport @proton_port dnat to ${peerHost}
      }
    '';
  };

  systemd.services.protonvpn-port = {
    description = "Renew the Proton forwarded port and publish it";
    after = [ "wireguard-wg-egress.service" ];
    path = [ pkgs.libnatpmp pkgs.nftables pkgs.curl pkgs.coreutils pkgs.gnused ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "protonvpn"; };
    environment.PEER_HOST = peerHost;
    script = "exec ${pkgs.bash}/bin/bash ${../scripts/protonvpn-port.sh}";
  };
  systemd.timers.protonvpn-port = {
    wantedBy = [ "timers.target" ];
    # the lease is 60s; a renewal that lands late is the same as none.
    timerConfig = { OnBootSec = "90s"; OnUnitActiveSec = "45s"; AccuracySec = "5s"; };
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # NAT + PORT FORWARDING
  # ─────────────────────────────────────────────────────────────────────────────
  networking.nat = {
    enable = true;
    externalInterface = "ens18";
    internalInterfaces = [ "ens19" "ens20" "wg0" ];
    # forwardPorts left empty, NixOS forwardPorts matches ALL inbound traffic on ens18,
    # hijacking LAN->10.100.0.x:443 to external traefik. Custom nftables below restrict
    # DNAT to traffic destined for the router's own WAN IP only.
    forwardPorts = [];
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # FIREWALL
  # ─────────────────────────────────────────────────────────────────────────────
  networking.nftables.enable = true;
  networking.firewall = {
    # Loose, to match the rp_filter sysctl above rather than contradict it.
    # The default strict check is `fib saddr . mark . iif check exists`, which
    # requires a reply to arrive on the interface the main table would use to
    # reach its source. Traffic that left through the VPN exit comes back on
    # wg-egress while 1.1.1.1 still routes via ens18, so every reply for an
    # egress member was dropped - the request reached the internet and the
    # answer was discarded one hop from home.
    checkReversePath = "loose";
    enable = true;
    filterForward = true;

    interfaces.ens18 = {
      allowedTCPPorts = [ 22 53 443 9001 10100 10200 25565 ];
      allowedUDPPorts = [ 53 51820 5353 ];
    };
    interfaces.ens19 = {
      allowedTCPPorts = [ 22 53 9100 ];
      allowedUDPPorts = [ 53 67 ];
    };
    interfaces.ens20 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 67 ];
    };
    interfaces.wg0 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };

    # per-source limits on traffic from the internet, applied before anything
    # reaches a service. Only drops: no accept rule here, so the normal
    # allowedTCPPorts logic still decides what is permitted.
    #
    # `meter` keys the limit on the source address, so one noisy host cannot
    # consume the budget of everybody else. Traefik has its own per-IP rate and
    # in-flight limits (modules/traefik.nix) for layer 7; these two cover the
    # layers below it, where Traefik never sees the packet.
    extraInputRules = ''
      iifname "ens18" tcp flags & (fin|syn|rst|ack) == syn \
        meter wan-syn size 65535 { ip saddr limit rate over 50/second burst 100 packets } \
        counter drop
      iifname "ens18" ct state new \
        meter wan-conns size 65535 { ip saddr ct count over 200 } \
        counter drop

      # Tor, for the lab only and never from the WAN. 9050 and 9055 are the
      # SOCKS ports an app points itself at (Prowlarr uses 9055 for
      # per-destination circuit isolation); 9040 and 9053 are where the egress
      # redirect lands a tor-class VM, which arrives here as ordinary input
      # because the translation happened on this host.
      ip saddr { 10.100.0.0/24, 10.200.0.0/24 } tcp dport { ${toString torPorts.socks}, ${toString torPorts.socksIsolated}, ${toString torPorts.trans}, ${toString torPorts.dns} } accept
      ip saddr { 10.100.0.0/24, 10.200.0.0/24 } udp dport ${toString torPorts.dns} accept
    '';

    extraForwardRules = ''
      ct state established,related accept

      # WAN -> all internal networks: allow
      iifname "ens18" accept

      # internal LAN -> anywhere: allow
      iifname "ens19" accept

      # WireGuard VPN -> anywhere: allow
      iifname "wg0" accept

      # allow DMZ to reach internal Traefik, Git, and Registry (for CI/CD + image pulls)
      iifname "ens20" ip daddr { 10.100.0.100, 10.100.0.115 } tcp dport { 80, 443 } accept
      iifname "ens20" ip daddr 10.100.0.118 tcp dport { 80, 443, 5000 } accept

      # allow DMZ VMs to ship logs to Loki on vm-105
      iifname "ens20" ip daddr 10.100.0.105 tcp dport 3100 accept

      # allow DMZ to reach NAS (NFS for persistent data)
      iifname "ens20" ip daddr 10.100.0.109 tcp dport { 111, 2049 } accept
      iifname "ens20" ip daddr 10.100.0.109 udp dport { 111, 2049 } accept

      # external DMZ -> internal LAN: BLOCK
      iifname "ens20" oifname "ens19" counter drop

      # allow external Traefik to reach the Proxmox API for on-demand VM wake.
      # narrow: only vm-200, only the hypervisor, only the API port. The token is
      # scoped to VM.PowerMgmt/VM.Audit. Must precede the management-net drop.
      iifname "ens20" ip saddr 10.200.0.200 ip daddr 192.168.178.200 tcp dport 8006 accept

      # external DMZ -> local/management network: BLOCK
      iifname "ens20" oifname "ens18" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } counter drop

      # external DMZ -> internet: allow
      iifname "ens20" accept
    '';
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # PORT FORWARDS (DNAT ONLY FOR ROUTER'S OWN WAN IP)
  # ─────────────────────────────────────────────────────────────────────────────
  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
        ip daddr 192.168.178.29 tcp dport 443 dnat to 10.200.0.200:443
        ip daddr 192.168.178.29 tcp dport 10100 dnat to 10.100.0.100:443
        ip daddr 192.168.178.29 tcp dport 10200 dnat to 10.200.0.200:443
        ip daddr 192.168.178.29 tcp dport 25565 dnat to 10.200.0.200:25565
        # Tor relay ORPort: must also be forwarded on the FritzBox.
        ip daddr 192.168.178.29 tcp dport 9001 dnat to 10.200.0.202:9001
        # No qBittorrent forward: peer traffic leaves through Proton now, and
        # the port peers reach it on is the one NAT-PMP leases inside that
        # tunnel. A forward here would point at a port the client no longer
        # listens on.
      }
    '';
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # DHCP SERVER (KEA)
  # ─────────────────────────────────────────────────────────────────────────────
  services.kea.dhcp4 = {
    enable = true;
    settings = {
      valid-lifetime = 3600;
      renew-timer = 900;
      rebind-timer = 1800;
      interfaces-config.interfaces = [ "ens19" "ens20" ];
      lease-database = {
        type = "memfile";
        persist = true;
        name = "/var/lib/kea/dhcp4.leases";
      };
      subnet4 = [
        {
          id = 1;
          subnet = "10.100.0.0/24";
          pools = [{ pool = "10.100.0.200 - 10.100.0.254"; }];
          option-data = [
            { name = "routers"; data = "10.100.0.1"; }
            { name = "domain-name-servers"; data = "10.100.0.1"; }
          ];
          interface = "ens19";
        }
        {
          id = 2;
          subnet = "10.200.0.0/24";
          pools = [{ pool = "10.200.0.210 - 10.200.0.254"; }];
          option-data = [
            { name = "routers"; data = "10.200.0.1"; }
            { name = "domain-name-servers"; data = "10.200.0.1"; }
          ];
          interface = "ens20";
        }
      ];
    };
  };

  # ─────────────────────────────────────────────────────────────────────────────
  # DNS BLOCKLIST + DOT UPSTREAM (BLOCKY)
  # ─────────────────────────────────────────────────────────────────────────────
  # loopback-only; CoreDNS forwards `.` here. Blocks ads/trackers/malware and
  # encrypts upstream queries over DNS-over-TLS to Cloudflare/Quad9.
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = "127.0.0.1:5335";
      upstreams.groups.default = [
        "tcp-tls:1.1.1.1:853"
        "tcp-tls:9.9.9.9:853"
      ];
      # resolve the DoT hostnames' bootstrap without a chicken-and-egg loop.
      bootstrapDns = [
        { upstream = "tcp-tls:1.1.1.1:853"; ips = [ "1.1.1.1" ]; }
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

  # ─────────────────────────────────────────────────────────────────────────────
  # DNS SERVER (COREDNS)
  # ─────────────────────────────────────────────────────────────────────────────
  # all services use *.lsck0.dev: internal DNS resolves to local traefik IPs
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      lsck0.dev:53 {
        hosts {
          # internal services -> internal Traefik
          ${lib.concatMapStringsSep "\n    " (h: "10.100.0.100 ${h}.lsck0.dev") (hostsOf "internal" ++ internalExtraHosts)}
          # direct: SMB/NFS on the NAS, sccache (Redis protocol)
          10.100.0.109 smb.lsck0.dev
          10.100.0.111 sccache.lsck0.dev
          # external services -> external Traefik
          ${lib.concatMapStringsSep "\n    " (h: "10.200.0.200 ${h}.lsck0.dev") (hostsOf "external" ++ [ "mc" ])}
          fallthrough
        }
        template IN SRV _minecraft._tcp.mc.lsck0.dev {
          answer "{{ .Name }} 3600 IN SRV 0 0 25565 mc.lsck0.dev."
        }
      }

      .:53 {
        # forward to local blocky (ad/tracker/malware blocklists + DoT upstream)
        # first; fall back to plain 1.1.1.1/8.8.8.8 if blocky is down, so DNS
        # for the whole LAN never depends on blocky staying up.
        forward . 127.0.0.1:5335 1.1.1.1 8.8.8.8 {
          policy sequential
          health_check 5s
        }
        cache 300
      }
    '';
  };

  # after first boot, get server pubkey: wg show wg0 public-key
  # Generate client config: endpoint = <public-ip>:51820, DNS = 10.0.0.1
  sops.secrets.wireguard-private-key = {};
  sops.secrets.cloudflare-token = {};

  # ─────────────────────────────────────────────────────────────────────────────
  # DDNS (CLOUDFLARE)
  # ─────────────────────────────────────────────────────────────────────────────
  systemd.services.ddns-cloudflare = {
    description = "Update vpn.lsck0.dev A record with current public IP";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.jq ];
    serviceConfig = {
      Type = "oneshot";
      EnvironmentFile = config.sops.secrets.cloudflare-token.path;
    };
    script = ''
      TOKEN=$(cat ${config.sops.secrets.cloudflare-token.path})
      ZONE_NAME="lsck0.dev"

      IP=$(curl -sf https://api.ipify.org)
      [ -z "$IP" ] && { echo "Failed to get public IP"; exit 1; }

      ZONE_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" | jq -r '.result[0].id')
      { [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; } && { echo "Failed to get zone ID"; exit 1; }

      # format: "domain:proxied", built from proxiedHosts/rawHosts in Nix so
      # this list is the single source of truth for public DNS. Every HTTP
      # service (internal + external) is proxied; L4 services stay raw.
      DOMAINS="${ddnsDomains}"

      for ENTRY in $DOMAINS; do
        DOMAIN="''${ENTRY%%:*}"
        PROXIED="''${ENTRY##*:}"

        RECORD=$(curl -sf -G -H "Authorization: Bearer $TOKEN" \
          --data-urlencode "name=$DOMAIN" \
          --data-urlencode "type=A" \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records")
        RECORD_ID=$(echo "$RECORD" | jq -r '.result[0].id // empty')
        CURRENT_IP=$(echo "$RECORD" | jq -r '.result[0].content // empty')
        CURRENT_PROX=$(echo "$RECORD" | jq -r '.result[0].proxied // empty')

        if [ "$CURRENT_IP" = "$IP" ] && [ "$CURRENT_PROX" = "$PROXIED" ]; then
          echo "$DOMAIN already points to $IP (proxied: $PROXIED)"
          continue
        fi

        if [ -n "$RECORD_ID" ]; then
          curl -sf -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
            -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":$PROXIED}" | jq -c .
          echo "Updated $DOMAIN: $CURRENT_IP -> $IP (proxied: $PROXIED)"
        else
          curl -sf -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
            -d "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$IP\",\"ttl\":1,\"proxied\":$PROXIED}" | jq -c .
          echo "Created $DOMAIN -> $IP (proxied: $PROXIED)"
        fi
      done
    '';
  };

  systemd.timers.ddns-cloudflare = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
  # ─────────────────────────────────────────────────────────────────────────────
  # WIREGUARD VPN
  # ─────────────────────────────────────────────────────────────────────────────
  # client config MUST include: DNS = 10.0.0.1
  # This enables split-horizon DNS so *.lsck0.dev resolves to internal IPs over VPN.
  # port 53 is already open on wg0 (see firewall above).
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.0.0.1/24" ];
    listenPort = 51820;
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
    ];
  };

  virtualisation.docker.enable = lib.mkForce false;

  # wake-on-LAN: wake luca-pc from VPN
  # Usage: ssh root@10.0.0.1 wol-pc
  environment.etc."profile.d/wol.sh".text = ''
    alias wol-pc='wakeonlan -i 192.168.178.255 10:ff:e0:e4:04:4a'
  '';

  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool wakeonlan
  ];
}
