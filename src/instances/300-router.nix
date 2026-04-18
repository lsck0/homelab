{ config, pkgs, lib, ... }: {
  networking.hostName = "luca-router";

  # ── Network Interfaces ──────────────────────────────────────
  # ens18 = WAN    → static lease from FritzBox
  # ens19 = Internal LAN  (10.100.0.0/24)
  # ens20 = External DMZ  (10.200.0.0/24)
  # wg0   = WireGuard VPN (10.0.0.0/24)

  networking.usePredictableInterfaceNames = lib.mkForce true;
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{ address = "192.168.178.29"; prefixLength = 24; }];
  networking.defaultGateway = { address = "192.168.178.1"; interface = "ens18"; };
  networking.interfaces.ens19.ipv4.addresses = [{ address = "10.100.0.1"; prefixLength = 24; }];
  networking.interfaces.ens20.ipv4.addresses = [{ address = "10.200.0.1"; prefixLength = 24; }];

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  # ── NAT + Port Forwarding ──────────────────────────────────
  networking.nat = {
    enable = true;
    externalInterface = "ens18";
    internalInterfaces = [ "ens19" "ens20" "wg0" ];
    forwardPorts = [
      # FritzBox forwards 443 → here, route to external traefik
      { destination = "10.200.0.200:443"; proto = "tcp"; sourcePort = 443; }
      # alternate ports for direct access (internal/external traefik)
      { destination = "10.100.0.100:443"; proto = "tcp"; sourcePort = 10100; }
      { destination = "10.200.0.200:443"; proto = "tcp"; sourcePort = 10200; }
      # non-HTTP services
      { destination = "10.200.0.200:25565"; proto = "tcp"; sourcePort = 25565; }
    ];
  };

  # ── Firewall ────────────────────────────────────────────────
  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;
    filterForward = true;

    interfaces.ens18 = {
      allowedTCPPorts = [ 22 443 10100 10200 25565 ];
      allowedUDPPorts = [ 51820 ];
    };
    interfaces.ens19 = {
      allowedTCPPorts = [ 22 53 9100 ];
      allowedUDPPorts = [ 53 67 ];
    };
    interfaces.ens20 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 67 ];
    };

    extraForwardRules = ''
      ct state established,related accept

      # WAN → all internal networks: allow
      iifname "ens18" accept

      # Internal LAN → anywhere: allow
      iifname "ens19" accept

      # WireGuard VPN → anywhere: allow
      iifname "wg0" accept

      # allow DMZ to reach internal Git and Registry (for CI/CD)
      iifname "ens20" ip daddr { 10.100.0.104, 10.100.0.107 } tcp dport { 80, 443 } accept

      # External DMZ → internal LAN: BLOCK
      iifname "ens20" oifname "ens19" counter drop

      # External DMZ → local/management network: BLOCK
      iifname "ens20" oifname "ens18" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } counter drop

      # External DMZ → internet: allow
      iifname "ens20" accept
    '';
  };

  # ── DHCP Server (Kea) ──────────────────────────────────────
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

  # ── DNS Server (CoreDNS) ─────────────────────────────────────
  # *.internal.home → internal Traefik, *.external.home → external Traefik
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      internal.home {
        template IN A {
          answer "{{ .Name }} 3600 IN A 10.100.0.100"
        }
      }

      external.home {
        template IN A {
          match "^mc\.external\.home\.$"
          answer "mc.external.home. 3600 IN A 10.200.0.205"
          fallthrough
        }
        template IN A {
          answer "{{ .Name }} 3600 IN A 10.200.0.200"
        }
        template IN SRV _minecraft._tcp.mc.external.home {
          answer "{{ .Name }} 3600 IN SRV 0 0 25565 mc.external.home."
        }
      }

      lsck0.dev {
        hosts {
          # internal services → internal Traefik
          10.100.0.100 auth.lsck0.dev homepage.lsck0.dev git.lsck0.dev registry.lsck0.dev
          10.100.0.100 cloud.lsck0.dev vault.lsck0.dev paperless.lsck0.dev
          10.100.0.100 hass.lsck0.dev jellyfin.lsck0.dev status.lsck0.dev
          10.100.0.100 huginn.lsck0.dev tasks.lsck0.dev
          10.100.0.100 grafana.lsck0.dev wiki.lsck0.dev abs.lsck0.dev
          10.100.0.100 torrent.lsck0.dev music.lsck0.dev read.lsck0.dev
          10.100.0.100 prowlarr.lsck0.dev sonarr.lsck0.dev radarr.lsck0.dev
          # external services → external Traefik
          10.200.0.200 hs.lsck0.dev shlink.lsck0.dev paste.lsck0.dev share.lsck0.dev mc.lsck0.dev
          fallthrough
        }
        template IN SRV _minecraft._tcp.mc.lsck0.dev {
          answer "{{ .Name }} 3600 IN SRV 0 0 25565 mc.lsck0.dev."
        }
      }

      . {
        forward . 1.1.1.1 8.8.8.8
        cache 300
      }
    '';
  };

  # ── WireGuard VPN ───────────────────────────────────────────
  networking.wireguard.interfaces.wg0 = {
    ips = [ "10.0.0.1/24" ];
    listenPort = 51820;
    generatePrivateKeyFile = true;
    privateKeyFile = "/etc/wireguard/private.key";
  };

  virtualisation.docker.enable = lib.mkForce false;

  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool
  ];
}
