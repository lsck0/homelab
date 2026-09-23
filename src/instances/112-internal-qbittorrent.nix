{ config, pkgs, lib, nasMount, nasPath, retry, ... }:
let
  # hosts that may use the WebUI API without a login: internal Traefik (itself
  # behind Authelia), the *arr VMs, the wiring VM and Hermes. Explicit /32s, so
  # an arbitrary LAN host cannot rewrite download paths across the NFS mounts.
  # 104 is the terminal dashboard collector (transfer rates and torrent list).
  # 1 is the router: it leases Proton's forwarded port and is the only thing
  # that may change listen_port (scripts/protonvpn-port.sh).
  apiClients = map (id: "10.100.0.${toString id}/32") [ 1 100 104 114 130 131 133 135 136 ];

  # Peer traffic goes out directly. It used to go through the Tor SOCKS5
  # gateway, and that is simply not a thing BitTorrent can do:
  # SOCKS5 over Tor carries TCP only, so every udp:// tracker announce came
  # back "Permission denied", DHT and uTP were impossible, and exit nodes drop
  # the peer protocol. The symptom was a torrent that knew about nine seeds and
  # held zero connections to any of them, with connection_status "firewalled".
  #
  # The indexer side is unaffected: Prowlarr still searches through the same
  # Tor gateway (a Socks5 indexer proxy, configured by arr-wire.sh), which is
  # plain HTTP and works fine. Searches stay private; the swarm sees this
  # WAN address.
  prefs = pkgs.writeText "qbittorrent-prefs.json" (builtins.toJSON {
    proxy_type = "None";
    proxy_bittorrent = false;
    proxy_peer_connections = false;
    proxy_misc = false;
    proxy_rss = false;
    # anonymous_mode suppresses the client fingerprint and the IP in tracker
    # announces. Without a proxy it buys little and some private trackers
    # refuse it, but it costs nothing on public ones.
    anonymous_mode = false;
    save_path = "/data/torrents";
    bypass_auth_subnet_whitelist_enabled = true;
    bypass_auth_subnet_whitelist = lib.concatStringsSep ", " apiClients;
    # back on: these are how a swarm is actually found. They were off only
    # because UDP cannot cross a SOCKS5 proxy.
    dht = true;
    pex = true;
    lsd = true;
    # The WebUI has to answer on 80, because that is where the *arr, Traefik,
    # Homepage and the dashboard collector all look, and with host networking
    # there is no publish to remap it. Binding it as the container's
    # unprivileged user needs the sysctl below.
    web_ui_port = 80;
    # The listen port is whatever Proton's NAT-PMP lease currently says;
    # protonvpn-port.service overwrites it. 6881 is only the value the client
    # starts on before the first lease arrives.
    listen_port = 6881;
    random_port = false;
    upnp = false;
    queueing_enabled = true;
    max_active_downloads = 5;
    # One torrent seeds at a time. Upstream is the scarce direction on a
    # domestic line, and a seed saturating it makes everything else in the
    # flat feel broken - a video call before a download.
    max_active_uploads = 1;
    # downloads plus the one upload slot, so a full download queue never
    # starves seeding of its slot.
    max_active_torrents = 6;
    dont_count_slow_torrents = true;
  });
in {
  networking.hostName = "vm-112";

  # ── egress ──────────────────────────────────────────────────────────────
  # No tunnel here any more. The exit moved to the router (modules/egress.nix
  # lists this VM as via = "vpn"), which holds the key this VM used to hold
  # and marks its packets by source address. Nothing on this VM knows about
  # Proton: it has an ordinary default route to 10.100.0.1, and the router
  # decides what happens next.
  #
  # The killswitch moved with it and is the same idea: the routing table the
  # mark selects ends in a blackhole, so when the tunnel is down this VM's
  # packets have nowhere to go rather than falling back to the house address.
  # Better than the old arrangement, where this VM had to have its own default
  # route removed and a list of LAN exceptions kept by hand - and where
  # getting that list wrong took the VM off the network entirely.

  networking.firewall.allowedTCPPorts = [ 80 ];

  # The peer port changes with every Proton lease, so it still cannot be
  # listed. It used to be covered by trusting wg0, the tunnel's own interface;
  # with the tunnel on the router, peer traffic arrives on eth0 instead, having
  # been forwarded, and still carries the peer's own public address.
  #
  # So the source is what is matched rather than the port. A public address can
  # only have reached this VM through that one forward: nothing else on the
  # network routes a public source here, and the router DNATs exactly the port
  # it has leased. Matching the private ranges out keeps this from widening
  # anything on the LAN side, where the WebUI is still the only open port.
  networking.firewall.extraInputRules = ''
    ip saddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } tcp dport 1024-65535 accept
    ip saddr != { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8 } udp dport 1024-65535 accept
  '';

  # qBittorrent runs as uid 1000 inside the container and, sharing the host's
  # network namespace, has to bind 80 itself.
  boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = 80;

  # the WebUI skips its login for the whitelisted API clients, so the port
  # itself must not be reachable from anywhere else. 6881 (peer traffic) stays
  # open. apiClients is the same list the whitelist uses.
  homelab.ingressOnly = {
    ports = [ 80 ];
    extraSources = apiClients;
  };
}
