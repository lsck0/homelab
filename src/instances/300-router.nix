{ config, pkgs, lib, inventory, nasClients, site, ... }:
let
  routes = import ../modules/catalog.nix { inherit inventory lib; };
  appsCatalog = import ../modules/apps.nix;

  # running guests of one zone, by address
  zoneHosts = type: lib.sort (a: b: a < b) (map (v: v.ip)
    (lib.filter (v: v.type == type && v.enabled != "false") (lib.attrValues inventory)));
  nasClientsIn = type: lib.concatStringsSep ", " (lib.filter (ip: lib.elem ip (zoneHosts type)) (lib.attrNames nasClients));
  dmzNasClients = nasClientsIn "external";

  # the apps zone: the swarm nodes and the ports their routing mesh publishes for the edge
  appsNodes = lib.concatStringsSep ", " (zoneHosts "apps");
  appsNasClients = nasClientsIn "apps";
  swarmManager = inventory.${toString appsCatalog.swarm.manager}.ip;
  appsPorts = lib.unique (lib.concatMap (a: map (p: toString p.port) (lib.attrValues a.paths))
    (lib.filter (a: a.enable) (lib.attrValues appsCatalog.apps)));

  # egress classes (modules/egress.nix)
  # policy routing keyed on source address
  egress = import ../modules/egress.nix;
  # vpn exit needs a mark and a table: fwmark -> routing table
  egressMarks = { vpn = { mark = 1; table = 100; }; };
  membersOf = via: lib.sort (a: b: a < b)
    (lib.mapAttrsToList (_: e: inventory.${toString e.vmid}.ip)
      (lib.filterAttrs (_: e: e.via == via && inventory ? ${toString e.vmid}) egress));
  vpnMembers = membersOf "vpn";
  vpnSet = lib.concatStringsSep ", " vpnMembers;
  # via = "tor" members leave through tor's transparent proxy on this router
  torMembers = membersOf "tor";
  torSet = lib.concatStringsSep ", " torMembers;
  privateRanges = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16";

  # 9050 for the router's own health check, 9055 isolated per destination for prowlarr's indexers,
  # trans and dns for via = "tor" guests
  torPorts = { trans = 9040; dns = 9053; socks = 9050; socksIsolated = 9055; };
  prowlarrHost = inventory."130".ip;
  vpnCfg = config.homelab.egress.vpn;
  # only member taking inbound through the exit
  peerHost = inventory."112".ip;
  hostsOf = side: lib.unique (map (r: r.host) (lib.attrValues routes.${side}));
  # internal traefik hosts without a vm route
  internalExtraHosts = [ "traefik" "proxmox" ];
  # external traefik answers these itself
  installHosts = lib.attrNames (import ../modules/install-hosts.nix);

  # cloudflare proxying comes from routes.nix `proxied`
  routeHosts = side: lib.mapAttrsToList (_: r: {
    inherit (r) host;
    proxied = r.proxied or true;
  }) routes.${side};
  allRouteHosts = routeHosts "internal" ++ routeHosts "external"
    ++ map (h: { host = h; proxied = true; }) internalExtraHosts;

  proxiedHosts = lib.unique (map (r: r.host) (lib.filter (r: r.proxied) allRouteHosts));
  # unproxied (raw wan ip): anubis-fronted routes
  rawHosts = lib.unique (
    map (r: r.host) (lib.filter (r: !r.proxied) allRouteHosts)
    ++ installHosts ++ [ "wg" "mc" "tor" "*" ]
  );
  # domain:proxied entries for the ddns loop
  ddnsDomains = lib.concatStringsSep " " (
    (map (h: "${h}.lsck0.dev:true") proxiedHosts)
    ++ (map (h: "${h}.lsck0.dev:false") rawHosts)
  );
in {
  networking.hostName = "luca-router";

  # mdns on wan only, fritzbox shows "luca-router"
  services.avahi = {
    enable = true;
    allowInterfaces = [ "ens18" ];
    # the default opens 5353 on every interface, dmz and wg-egress included
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

  # NETWORK INTERFACES (ens18 wan, ens19 internal, ens20 dmz, ens21 apps), in terraform's router_zones order

  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{ address = site.lan.router; prefixLength = lib.toInt (lib.last (lib.splitString "/" site.lan.subnet)); }];
  networking.defaultGateway = { address = site.lan.gateway; interface = "ens18"; };
  networking.interfaces.ens19.ipv4.addresses = [{ address = "10.100.0.1"; prefixLength = 24; }];
  networking.interfaces.ens20.ipv4.addresses = [{ address = "10.200.0.1"; prefixLength = 24; }];
  networking.interfaces.ens21.ipv4.addresses = [{ address = "10.150.0.1"; prefixLength = 24; }];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;

    # volumetric / spoofing hardening on the edge
    # syn cookies survive a syn flood statelessly
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_max_syn_backlog" = 4096;
    "net.ipv4.tcp_synack_retries" = 2;
    # loose rpf: drop sources with no route
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
    # conntrack headroom outlasts per-source meters
    "net.netfilter.nf_conntrack_max" = 262144;
  };

  # EGRESS CLASSES (mark by source, table ends in blackhole)
  assertions = [
    {
      assertion = vpnMembers == [ ] || vpnCfg.enable;
      message = "modules/egress.nix routes ${vpnSet} through the VPN, but homelab.egress.vpn is not enabled on the router.";
    }
    {
      assertion = lib.all (e: lib.elem e.via [ "vpn" "tor" ]) (lib.attrValues egress);
      message = "modules/egress.nix: via must be \"vpn\" or \"tor\".";
    }
  ];

  networking.nftables.tables.egress = lib.mkIf (vpnMembers != [ ] || torMembers != [ ]) {
    family = "ip";
    content = lib.optionalString (vpnMembers != [ ]) ''
      chain premark {
        type filter hook prerouting priority mangle; policy accept;
        # never divert lab/house traffic, ssh replies blackhole
        ip daddr { ${privateRanges} } return
        ip saddr { ${vpnSet} } meta mark set ${toString egressMarks.vpn.mark}
      }
      # stateless, ahead of nixos-fw: a lost rule or route must never leak through the house
      chain killswitch {
        type filter hook forward priority filter - 5; policy accept;
        ip saddr { ${vpnSet} } oifname "ens18" ip daddr != { ${privateRanges} } counter drop
      }
    '' + lib.optionalString (torMembers != [ ]) ''
      chain tor-redirect {
        type nat hook prerouting priority dstnat - 3; policy accept;
        # exit nodes cannot route private ranges
        ip daddr { ${privateRanges} } return
        # dns first to get tor virtual addresses
        ip saddr { ${torSet} } udp dport 53 redirect to :${toString torPorts.dns}
        ip saddr { ${torSet} } tcp dport 53 redirect to :${toString torPorts.dns}
        ip saddr { ${torSet} } tcp flags & (fin|syn|rst|ack) == syn redirect to :${toString torPorts.trans}
      }
      chain tor-drop {
        type filter hook forward priority filter - 5; policy accept;
        # non-dns udp, tor cannot carry it
        ip saddr { ${torSet} } ct state established,related accept
        ip saddr { ${torSet} } counter drop
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
      set -eu
      ip rule del fwmark ${toString egressMarks.vpn.mark} table ${toString egressMarks.vpn.table} 2>/dev/null || true
      ip rule add fwmark ${toString egressMarks.vpn.mark} table ${toString egressMarks.vpn.table} priority 101
      # tunnel down: drop, never fall back to house
      ip route replace blackhole default metric 1000 table ${toString egressMarks.vpn.table}

      # rpfilter checks source against the marked table
      ip route replace 10.100.0.0/24 dev ens19 table ${toString egressMarks.vpn.table}
      ip route replace 10.200.0.0/24 dev ens20 table ${toString egressMarks.vpn.table}
      ip route replace 10.150.0.0/24 dev ens21 table ${toString egressMarks.vpn.table}
      ip route replace ${site.lan.subnet} dev ens18 table ${toString egressMarks.vpn.table}
    '';
  };

  # TOR SOCKS
  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;
    client = {
      enable = true;
      socksListenAddress = { addr = "10.100.0.1"; port = torPorts.socks; };
    };
    settings = {
      SocksPolicy = [ "accept ${prowlarrHost}" "accept 10.100.0.1" "reject *" ];
      # transparent pair for via = "tor" guests
      TransPort = [{ addr = "10.100.0.1"; port = torPorts.trans; }];
      DNSPort = [{ addr = "10.100.0.1"; port = torPorts.dns; }];
      AutomapHostsOnResolve = true;
      # keeps dnsport answers routable by transport
      VirtualAddrNetworkIPv4 = "10.192.0.0/10";

      # isolated socks port for indexers (prowlarr)
      SOCKSPort = [{
        addr = "10.100.0.1";
        port = torPorts.socksIsolated;
        IsolateDestAddr = true;
        IsolateDestPort = true;
      }];
      ClientUseIPv6 = false;

      # path rotation
      MaxCircuitDirtiness = 600;
      NewCircuitPeriod = 120;
      CircuitBuildTimeout = 30;

      ControlPort = [{ addr = "127.0.0.1"; port = 9051; }];
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
      printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" | nc -w 5 127.0.0.1 9051
    '';
  };
  systemd.timers.tor-new-circuits = {
    wantedBy = [ "timers.target" ];
    # jitter so rotation is no clock fingerprint
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "30m"; RandomizedDelaySec = "10m"; };
  };

  # tunnel and default route: modules/egress-vpn.nix
  homelab.egress.vpn = {
    enable = true;
    table = egressMarks.vpn.table;
    # former vm-112 key, clients cannot share one
    privateKeyFile = config.sops.secrets.protonvpn-private-key.path;
    address = "10.2.0.2/32";
    publicKey = "36G8+pInNcPK9F1TpHglWs9Pk5uJOY9o8SCNrCBgvHE=";
    # CH#684; address since dns is in the tunnel
    endpoint = "89.222.96.158:51820";
  };
  sops.secrets.protonvpn-private-key = { };

  # Proton's forwarded port
  # port changes every lease, renewal rewrites the set
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
    path = [ pkgs.libnatpmp pkgs.nftables pkgs.curl pkgs.coreutils pkgs.gnused pkgs.jq ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "protonvpn"; };
    environment.PEER_HOST = peerHost;
    script = "exec ${pkgs.bash}/bin/bash ${../scripts/protonvpn-port.sh}";
  };
  systemd.timers.protonvpn-port = {
    wantedBy = [ "timers.target" ];
    # 60s lease, a late renewal is none
    timerConfig = { OnBootSec = "90s"; OnUnitActiveSec = "45s"; AccuracySec = "5s"; };
  };

  # ssh and node-exporter only where the firewall interfaces above open them, never the dmz or wg-egress
  services.openssh.openFirewall = false;
  services.prometheus.exporters.node.openFirewall = false;

  # NAT + PORT FORWARDING
  networking.nat = {
    enable = true;
    externalInterface = "ens18";
    internalInterfaces = [ "ens19" "ens20" "ens21" "wg0" ];
    # nixos forwardPorts would match all wan traffic
    forwardPorts = [];
  };

  # FIREWALL
  networking.nftables.enable = true;
  networking.firewall = {
    # strict drops every vpn reply
    checkReversePath = "loose";
    enable = true;
    filterForward = true;

    interfaces.ens18 = {
      # 443 and 25565 are dnat'd, the router itself listens on neither
      allowedTCPPorts = [ 22 53 ];
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
    # static addresses from terraform, so dns only
    interfaces.ens21 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
    };
    interfaces.wg0 = {
      allowedTCPPorts = [ 22 53 ];
      allowedUDPPorts = [ 53 ];
    };

    # the router's own health check reaches 9050 over loopback
    extraInputRules = ''
      ip saddr ${prowlarrHost} tcp dport ${toString torPorts.socksIsolated} accept
    '' + lib.optionalString (torMembers != [ ]) ''
      ip saddr { ${torSet} } tcp dport { ${toString torPorts.trans}, ${toString torPorts.dns} } accept
      ip saddr { ${torSet} } udp dport ${toString torPorts.dns} accept
    '';

    # nixos-fw accepts established flows before these, they only see new ones
    extraForwardRules = ''
      # wan: port forwards only; the house lan routes the lab through here, but reaches the apps only through the ingresses
      iifname "ens18" ct status dnat accept
      # the workstation deploys the apps nodes over ssh like every guest
      iifname "ens18" ip saddr ${site.lan.workstation} oifname "ens21" tcp dport 22 accept
      iifname "ens18" oifname "ens21" counter drop
      iifname "ens18" ip saddr ${site.lan.subnet} accept

      # lan -> anywhere: allow
      iifname "ens19" accept

      # wireguard -> anywhere: allow
      iifname "wg0" accept

      # dmz -> internal traefik: *.lsck0.dev resolves there for git and the registry too
      iifname "ens20" ip daddr 10.100.0.100 tcp dport { 80, 443 } accept

      # dmz -> loki on vm-105: promtail pushes from the external traefik only, journals from every guest
      iifname "ens20" ip saddr 10.200.0.200 ip daddr 10.100.0.105 tcp dport 3100 accept
      iifname "ens20" ip daddr 10.100.0.105 tcp dport 19532 accept

      # dmz -> nas nfs, only from the guests vm-109 exports to
      iifname "ens20" ip saddr { ${dmzNasClients} } ip daddr 10.100.0.109 meta l4proto { tcp, udp } th dport { 111, 2049 } accept

      # vm-200 -> proxmox api for wake
      iifname "ens20" ip saddr 10.200.0.200 ip daddr ${site.lan.proxmox} tcp dport 8006 accept

    '' + lib.optionalString (appsPorts != [ ]) ''
      # edge -> the apps' published ports; the swarm's routing mesh answers on every node
      iifname "ens20" ip saddr 10.200.0.200 ip daddr { ${appsNodes} } tcp dport { ${lib.concatStringsSep ", " appsPorts} } accept
    '' + ''

      # dmz -> lan, management net, wireguard clients, apps: block, whichever interface routes it
      iifname "ens20" ip daddr { ${privateRanges} } counter drop

      # dmz -> internet: allow
      iifname "ens20" accept

      # apps -> internal traefik: registry pulls
      iifname "ens21" ip daddr 10.100.0.100 tcp dport 443 accept
      # apps -> vm-105: journals, otlp traces, pyroscope profiles
      iifname "ens21" ip daddr 10.100.0.105 tcp dport { 19532, 4317, 4040 } accept
      # workers -> their manager: control (2377), gossip (7946), overlay (4789) and its ipsec (esp)
      iifname "ens21" ip daddr ${swarmManager} tcp dport { 2377, 7946 } accept
      iifname "ens21" ip daddr ${swarmManager} udp dport { 7946, 4789 } accept
      iifname "ens21" ip daddr ${swarmManager} meta l4proto esp accept
    '' + lib.optionalString (appsNasClients != "") ''
      # apps -> nas nfs, only the nodes vm-109 exports to
      iifname "ens21" ip saddr { ${appsNasClients} } ip daddr 10.100.0.109 meta l4proto { tcp, udp } th dport { 111, 2049 } accept
    '' + ''
      # apps -> lab, house, dmz, wireguard clients: block
      iifname "ens21" ip daddr { ${privateRanges} } counter drop

      # apps -> internet: allow
      iifname "ens21" accept
    '';
  };

  # per-source wan limits ahead of every accept, dnat'd ports included; the house lan shares ens18 and is exempt
  networking.nftables.tables.wan-limits = {
    family = "ip";
    content = ''
      chain prerouting {
        type filter hook prerouting priority filter - 1; policy accept;
        ip saddr ${site.lan.subnet} return
        iifname "ens18" tcp flags & (fin|syn|rst|ack) == syn \
          meter wan-syn size 65535 { ip saddr limit rate over 50/second burst 100 packets } \
          counter drop
        iifname "ens18" ct state new \
          meter wan-conns size 65535 { ip saddr ct count over 200 } \
          counter drop
      }
    '';
  };

  # PORT FORWARDS (DNAT ONLY FOR ROUTER'S OWN WAN IP)
  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
        ip daddr ${site.lan.router} tcp dport 443 dnat to 10.200.0.200:443
        ip daddr ${site.lan.router} tcp dport 25565 dnat to 10.200.0.200:25565
        # no qbittorrent forward, peers arrive via proton
      }
    '';
  };

  # DHCP SERVER (KEA)
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
          # .210 is vm-210's static address
          pools = [{ pool = "10.200.0.211 - 10.200.0.254"; }];
          option-data = [
            { name = "routers"; data = "10.200.0.1"; }
            { name = "domain-name-servers"; data = "10.200.0.1"; }
          ];
          interface = "ens20";
        }
      ];
    };
  };

  # DNS BLOCKLIST + DOT UPSTREAM (BLOCKY, loopback only)
  services.blocky = {
    enable = true;
    settings = {
      ports.dns = "127.0.0.1:5335";
      upstreams.groups.default = [
        "tcp-tls:1.1.1.1:853"
        "tcp-tls:9.9.9.9:853"
      ];
      # bootstrap dot hostnames without a dns loop
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

  # DNS SERVER (COREDNS, split horizon for *.lsck0.dev)
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      lsck0.dev:53 {
        hosts {
          # internal services -> internal traefik
          ${lib.concatMapStringsSep "\n    " (h: "10.100.0.100 ${h}.lsck0.dev") (hostsOf "internal" ++ internalExtraHosts)}
          # direct: nas smb/nfs, sccache redis
          10.100.0.109 smb.lsck0.dev
          10.100.0.110 sccache.lsck0.dev
          # external services -> external traefik
          ${lib.concatMapStringsSep "\n    " (h: "10.200.0.200 ${h}.lsck0.dev") (hostsOf "external" ++ installHosts ++ [ "mc" ])}
          fallthrough
        }
        # unlisted names (mx, txt, public-only records) resolve like the rest
        forward . 127.0.0.1:5335 1.1.1.1 8.8.8.8 {
          policy sequential
          health_check 5s
        }
        template IN SRV _minecraft._tcp.mc.lsck0.dev {
          answer "{{ .Name }} 3600 IN SRV 0 0 25565 mc.lsck0.dev."
        }
      }

      .:53 {
        # blocky first, plain fallback so dns survives it
        forward . 127.0.0.1:5335 1.1.1.1 8.8.8.8 {
          policy sequential
          health_check 5s
        }
        cache 300
      }
    '';
  };

  # server pubkey: wg show wg0 public-key
  sops.secrets.wireguard-private-key = {};
  sops.secrets.cloudflare-token = {};

  # DDNS (CLOUDFLARE)
  systemd.services.ddns-cloudflare = {
    description = "Point the lsck0.dev A records at the current public IP";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.jq pkgs.findutils ];
    # /run starts empty, so every boot does a full sync
    serviceConfig = { Type = "oneshot"; RuntimeDirectory = "ddns-cloudflare"; RuntimeDirectoryPreserve = true; };
    script = ''
      # a failed cloudflare call must not record the ip as synced
      set -o pipefail
      IP=$(curl -sf https://api.ipify.org)
      [ -z "$IP" ] && { echo "Failed to get public IP"; exit 1; }

      # unchanged ip: only the hourly full sync talks to cloudflare
      LAST=/run/ddns-cloudflare/ip
      if [ "$(cat $LAST 2>/dev/null)" = "$IP" ] && [ -n "$(find $LAST -mmin -60)" ]; then
        exit 0
      fi

      TOKEN=$(cat ${config.sops.secrets.cloudflare-token.path})
      ZONE_NAME="lsck0.dev"

      ZONE_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$ZONE_NAME" | jq -r '.result[0].id')
      { [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; } && { echo "Failed to get zone ID"; exit 1; }

      # "domain:proxied", generated from routes.nix
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
        # tostring: `// empty` turned proxied=false into empty and re-put every unproxied record each run
        CURRENT_PROX=$(echo "$RECORD" | jq -r '.result[0].proxied | tostring')

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
      echo -n "$IP" > $LAST
    '';
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
      { # pc, config in secrets repo wg0.pc.conf
        publicKey = "rvtqHdSDK3JGZhZkzVYIcb9gKHiZUTsenfpJtm4adT0=";
        allowedIPs = [ "10.0.0.5/32" ];
      }
    ];
  };

  virtualisation.docker.enable = lib.mkForce false;

  # wol-pc wakes luca-pc from the vpn
  environment.etc."profile.d/wol.sh".text = ''
    alias wol-pc='wakeonlan ${site.lan.workstationMac}'
  '';

  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool wakeonlan
  ];
}
