{ pkgs, ... }:
let
  # force a fresh set of circuits on a schedule. MaxCircuitDirtiness below only
  # stops *new* streams from reusing an old circuit; NEWNYM also retires the
  # ones already in use, so a long-lived torrent session does not sit on the
  # same three relays for days.
  newCircuits = pkgs.writeShellScript "tor-new-circuits" ''
    set -euo pipefail
    export PATH="${pkgs.lib.makeBinPath [ pkgs.coreutils pkgs.netcat-gnu pkgs.xxd ]}"
    cookie=$(xxd -p -c 256 /var/lib/tor/control_auth_cookie)
    printf 'AUTHENTICATE %s\r\nSIGNAL NEWNYM\r\nQUIT\r\n' "$cookie" | nc -w 5 127.0.0.1 9051
  '';
in {
  networking.hostName = "vm-113";

  # SOCKS5 gateway into the Tor network for internal VMs. Client only -
  # this node relays nothing. The public non-exit relay is vm-202.
  services.tor = {
    enable = true;
    enableGeoIP = false;
    relay.enable = false;

    client = {
      enable = true;
      socksListenAddress = {
        addr = "10.100.0.113";
        port = 9050;
        # per-destination circuit isolation is the usual client default, but a
        # torrent client opens connections to hundreds of peers at once and
        # would build a circuit for each. Keep connections on shared circuits.
        IsolateDestAddr = false;
      };
    };

    settings = {
      # only the internal LAN may use this proxy.
      SocksPolicy = [ "accept 10.100.0.0/24" "reject *" ];

      # second SOCKS port for the indexers (Prowlarr, vm-129). Indexer traffic
      # is a handful of requests to a handful of sites, so it gets real stream
      # isolation: a separate circuit per destination, and a separate circuit
      # from the torrent traffic on 9050. The list merges with the one
      # services.tor.client.socksListenAddress generates.
      SOCKSPort = [{
        addr = "10.100.0.113";
        port = 9055;
        IsolateDestAddr = true;
        IsolateDestPort = true;
      }];

      # path rotation. Tor picks a new guard rarely by design (rotating guards
      # is what deanonymises you), but the middle and exit relays turn over:
      #   MaxCircuitDirtiness  a circuit stops taking new streams after 10 min
      #   NewCircuitPeriod     consider building a fresh circuit every 2 min
      # combined with the NEWNYM timer below, the exit address a tracker or an
      # indexer sees changes several times an hour.
      MaxCircuitDirtiness = 600;
      NewCircuitPeriod = 120;
      CircuitBuildTimeout = 30;

      # control port for the NEWNYM signal, loopback only, cookie authenticated.
      ControlPort = [{ addr = "127.0.0.1"; port = 9051; }];
      CookieAuthentication = true;

      # DNS resolver for callers that cannot resolve through SOCKS5 themselves.
      DNSPort = [{ addr = "10.100.0.113"; port = 9053; }];
      AutomapHostsOnResolve = true;
      ClientUseIPv6 = false;
    };
  };

  systemd.services.tor-new-circuits = {
    description = "Ask Tor for a fresh set of circuits";
    after = [ "tor.service" ];
    requires = [ "tor.service" ];
    serviceConfig = { Type = "oneshot"; ExecStart = newCircuits; };
  };
  systemd.timers.tor-new-circuits = {
    wantedBy = [ "timers.target" ];
    # randomised so the rotation is not itself a clock-like fingerprint.
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "30m"; RandomizedDelaySec = "10m"; };
  };

  # Fresh link-layer address on every boot. This is the useful half of what
  # ID-Spoofer (github.com/NubleX/ID-Spoofer) does; the rest of that tool is not
  # applicable here, and it is worth being precise about why:
  #
  #   MAC address      never leaves the Proxmox bridge. Everything this VM sends
  #                    is NATed by the router and then tunnelled through Tor, so
  #                    no remote party ever sees it. Randomising it per boot
  #                    costs nothing, so it is done; rotating it at runtime
  #                    would drop the link on a statically addressed VM and buy
  #                    no anonymity at all.
  #   TCP/IP fingerprint  likewise terminates at the Tor client. A tracker sees
  #                    the exit relay's stack, not this one.
  #   DHCP hostname    unused: addresses come from cloud-init, not DHCP.
  #
  # What a remote party actually sees is the exit relay (rotated above) and the
  # application-level identity: qBittorrent runs with anonymous_mode, which
  # strips its client fingerprint and peer_id from tracker announces
  # (111-internal-qbittorrent.nix).
  environment.etc."systemd/network/10-eth0-random-mac.link".text = ''
    [Match]
    OriginalName=eth0

    [Link]
    MACAddressPolicy=random
  '';

  networking.firewall.allowedTCPPorts = [ 9050 9055 ];
  networking.firewall.allowedUDPPorts = [ 9053 ];
}
