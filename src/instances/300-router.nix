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
    # forwardPorts left empty — NixOS forwardPorts matches ALL inbound traffic on ens18,
    # hijacking LAN→10.100.0.x:443 to external traefik. Custom nftables below restrict
    # DNAT to traffic destined for the router's own WAN IP only.
    forwardPorts = [];
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
    interfaces.wg0 = {
      allowedTCPPorts = [ 53 ];
      allowedUDPPorts = [ 53 ];
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
      iifname "ens20" ip daddr { 10.100.0.105, 10.100.0.108 } tcp dport { 80, 443 } accept

      # allow DMZ to reach NAS (NFS for persistent data)
      iifname "ens20" ip daddr 10.100.0.111 tcp dport { 111, 2049 } accept
      iifname "ens20" ip daddr 10.100.0.111 udp dport { 111, 2049 } accept

      # External DMZ → internal LAN: BLOCK
      iifname "ens20" oifname "ens19" counter drop

      # External DMZ → local/management network: BLOCK
      iifname "ens20" oifname "ens18" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } counter drop

      # External DMZ → internet: allow
      iifname "ens20" accept
    '';
  };

  # ── Port Forwards (DNAT only for router's own WAN IP) ─────
  networking.nftables.tables.port-forwards = {
    family = "ip";
    content = ''
      chain prerouting {
        type nat hook prerouting priority dstnat - 1; policy accept;
        ip daddr 192.168.178.29 tcp dport 443 dnat to 10.200.0.200:443
        ip daddr 192.168.178.29 tcp dport 10100 dnat to 10.100.0.100:443
        ip daddr 192.168.178.29 tcp dport 10200 dnat to 10.200.0.200:443
        ip daddr 192.168.178.29 tcp dport 25565 dnat to 10.200.0.200:25565
      }
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
  # *.internal → internal Traefik, *.external → external Traefik
  services.resolved.enable = false;
  services.coredns = {
    enable = true;
    config = ''
      internal {
        template IN A {
          answer "{{ .Name }} 3600 IN A 10.100.0.100"
        }
      }

      external {
        template IN A {
          match "^mc\.external\.$"
          answer "mc.external. 3600 IN A 10.200.0.205"
          fallthrough
        }
        template IN A {
          answer "{{ .Name }} 3600 IN A 10.200.0.200"
        }
        template IN SRV _minecraft._tcp.mc.external {
          answer "{{ .Name }} 3600 IN SRV 0 0 25565 mc.external."
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
          10.100.0.100 nas.lsck0.dev proxmox.lsck0.dev traefik.lsck0.dev
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
  # After first boot, get server pubkey: wg show wg0 public-key
  # Generate client config with that key + endpoint = <your-public-ip>:51820
  sops.secrets.wireguard-private-key = {};
  sops.secrets.cloudflare-token = {};

  # ── DDNS (Cloudflare) ──────────────────────────────────────
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
      [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ] && { echo "Failed to get zone ID"; exit 1; }

      # format: "domain:proxied"
      DOMAINS="wg.lsck0.dev:false mc.lsck0.dev:false *.lsck0.dev:true"

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

  # Wake-on-LAN: wake luca-pc from VPN
  # Usage: ssh root@10.0.0.1 wol-pc
  environment.etc."profile.d/wol.sh".text = ''
    alias wol-pc='wakeonlan -i 192.168.178.255 10:ff:e0:e4:04:4a'
  '';

  environment.systemPackages = with pkgs; [
    tcpdump iperf3 wireguard-tools ethtool wakeonlan
  ];
}
