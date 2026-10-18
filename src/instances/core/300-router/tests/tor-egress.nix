# the tor egress class (`profiles.torEgress`) on the real router: a member's internet tcp ends at tor's
# TransPort, is refused while tor is down and dropped once the redirect is gone, its udp has no way out and nothing
# of it reaches the house; its names go to tor's DNSPort, its lab traffic stays direct. A vpn member and a plain
# guest beside it keep their own paths: the tunnel, and the house masqueraded.
#
# No instance routes through tor, so the test makes one: the router reads the class from lab.egress alone (flows.nix,
# main.nix), which the test's facts extend by a guest of the internal zone. Nodes: the router, `house` (the fritzbox,
# a house device and the internet stand-in), `internal` (the member, the vpn member, a plain guest).
{ pkgs, lib, specialArgs, seed ? 1, ... }:
let
  lab = import ../../../../tests/lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../../../../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  torPorts = import ../../../../modules/tor-ports.nix;
  ip = id: lab.inventory.${id}.ip;

  memberId = "131";
  vpnMemberId = lib.head (lib.attrNames (lib.filterAttrs (id: e: e.via == "vpn" && (net.zoneOf id).name == "internal") lab.egress));
  plainId = "103";
  facts = lab.specialArgs // {
    lab = lab.specialArgs.lab // { egress = lab.egress // { ${memberId} = { via = "tor"; inbound = false; vmid = lib.toInt memberId; }; }; };
  };

  house = { fritzbox = net.wan.gateway; device = "192.168.178.50"; internet = "198.51.100.7"; };
  guests = { member = ip memberId; vpnMember = ip vpnMemberId; plain = ip plainId; };
  routerInternal = net.zones.internal.routerIp;
  # no port the policy names: only this test's probes use it
  probePort = 4444;

  tools = { environment.systemPackages = [ pkgs.dig pkgs.netcat pkgs.tcpdump ]; };
in
pkgs.testers.runNixOSTest {
  name = "tor-egress";
  passthru.regressionSeeds = [ ];
  node.specialArgs = facts;

  nodes.luca-router = { imports = [ lab.router tools ]; virtualisation.memorySize = 1024; };
  nodes.house = {
    imports = [ (lab.multi {
      addresses = map (a: "${a}/24") (lib.attrValues house);
      routes = [ { address = "10.0.0.0"; prefixLength = 8; via = net.wan.address; } ];
    }) tools ];
  };
  nodes.internal = {
    imports = [ (lab.multi {
      vlan = lab.vlans.internal;
      addresses = map (a: "${a}/24") (lib.attrValues guests);
      gateway = routerInternal;
    }) tools ];
  };

  testScript = lab.driverPython + ''
    import re

    SEED = ${toString seed}
    HOUSE = json.loads('${builtins.toJSON house}')
    GUESTS = json.loads('${builtins.toJSON guests}')
    ROUTER_WAN = "${net.wan.address}"
    ROUTER = "${routerInternal}"
    PORT = ${toString probePort}
    MEMBER, VPN_MEMBER, PLAIN = GUESTS["member"], GUESTS["vpnMember"], GUESTS["plain"]
    sources = {a: internal for a in GUESTS.values()}

    def capture_start(machine, interface, pcap, bpf):
        machine.succeed(f"tcpdump -n -U -i {interface} -w {pcap} '{bpf}' > {pcap}.log 2>&1 & echo $! > {pcap}.pid")
        machine.wait_until_succeeds(f"grep -q 'listening on' {pcap}.log", timeout=30)

    # flags -A: the payload as text, so a query to tor's DNSPort (no port tcpdump decodes as dns) shows its name
    def capture_read(machine, pcap, flags=""):
        return machine.succeed(f"tcpdump -n {flags} -r {pcap} 2>/dev/null")

    def capture_stop(machine, pcap, flags=""):
        machine.succeed(f"kill -INT $(cat {pcap}.pid)")
        machine.wait_until_fails(f"kill -0 $(cat {pcap}.pid)", timeout=30)
        return capture_read(machine, pcap, flags)

    def counter(chain, marker):
        out = luca_router.succeed(f"nft list chain ip egress {chain}")
        line = next(l for l in out.splitlines() if marker in l)
        return int(re.search(r"counter packets (\d+)", line).group(1))

    def connects(src, dst):
        return internal.execute(f"nc -z -w 2 -s {src} {dst} {PORT}")[0] == 0

    start_all()
    luca_router.wait_for_unit("multi-user.target")
    house.wait_for_unit("network.target")
    internal.wait_for_unit("network.target")
    luca_router.wait_until_succeeds("ss -ltnH 'sport = :${toString torPorts.trans}' | grep -q '${routerInternal}:'", timeout=60)
    probe_sinks_start([house], tcp=(PORT,), udp=(PORT,))

    with subtest("a tor member's internet traffic goes into tor or nowhere, never through the house"):
        capture_start(house, "eth1", "/tmp/leak.pcap", f"host {HOUSE['internet']} or host {HOUSE['device']}")
        before = counter("torredirect", MEMBER)
        # tor's transparent port accepts it: the only listener the redirect leads to
        assert connects(MEMBER, HOUSE["internet"]), "the member's tcp did not reach tor's TransPort"
        assert counter("torredirect", MEMBER) > before, "the member's tcp was not redirected"
        luca_router.succeed("systemctl stop tor")
        assert not connects(MEMBER, HOUSE["internet"]), "tor is down, yet the member's tcp connected"
        luca_router.succeed("systemctl start tor")
        luca_router.succeed("nft flush chain ip egress torredirect")
        before = counter("killswitch", MEMBER)
        assert not connects(MEMBER, HOUSE["internet"]), "the redirect is gone, yet the member's tcp connected"
        internal.fail(f"ping -c 1 -W 2 -I {MEMBER} {HOUSE['internet']}")
        assert counter("killswitch", MEMBER) > before, "the killswitch saw nothing once the redirect was gone"
        luca_router.succeed("systemctl restart nftables")
        probe_check([
            {"src": MEMBER, "dst": HOUSE["internet"], "proto": "udp", "port": PORT, "expect": "closed"},
            # lab and house traffic stays direct
            {"src": MEMBER, "dst": HOUSE["device"], "proto": "tcp", "port": PORT, "expect": "open", "seen_src": ROUTER_WAN},
            # positive control inside the capture: a plain guest to the house, which the capture must see
            {"src": PLAIN, "dst": HOUSE["device"], "proto": "udp", "port": PORT, "expect": "open", "seen_src": ROUTER_WAN},
        ], sources=sources, sinks=[house], seed=SEED)
        house.wait_until_succeeds(f"tcpdump -n -r /tmp/leak.pcap 2>/dev/null | grep -q '> {HOUSE['device']}.{PORT}:'", timeout=10)
        leak = [l for l in capture_stop(house, "/tmp/leak.pcap").splitlines() if HOUSE["internet"] in l]
        assert not leak, "a tor member's traffic left through the house:\n" + "\n".join(leak)

    with subtest("a vpn member still leaves through the tunnel, a plain guest through the house"):
        capture_start(luca_router, "wg-egress", "/tmp/tunnel.pcap", f"tcp port {PORT}")
        before = counter("torredirect", MEMBER)
        probe_check([
            # the tunnel is offline here: the member's connection dies inside it
            {"src": VPN_MEMBER, "dst": HOUSE["internet"], "proto": "tcp", "port": PORT, "expect": "closed"},
            {"src": PLAIN, "dst": HOUSE["internet"], "proto": "tcp", "port": PORT, "expect": "open", "seen_src": ROUTER_WAN},
            {"src": PLAIN, "dst": HOUSE["internet"], "proto": "udp", "port": PORT, "expect": "open", "seen_src": ROUTER_WAN},
        ], sources=sources, sinks=[house], seed=SEED)
        # masqueraded onto the provider's address: the only connection into the tunnel is the vpn member's
        luca_router.wait_until_succeeds(f"tcpdump -n -r /tmp/tunnel.pcap 2>/dev/null | grep -q '> {HOUSE['internet']}.{PORT}:'", timeout=10)
        capture_stop(luca_router, "/tmp/tunnel.pcap")
        assert counter("torredirect", MEMBER) == before, "tor took a connection that was not its member's"

    with subtest("a tor member's names go to tor's DNSPort, everyone else's elsewhere; the split horizon answers it"):
        capture_start(luca_router, "lo", "/tmp/tor-dns.pcap", "udp port ${toString torPorts.dns}")
        internal.execute(f"dig +time=2 +tries=1 -b {MEMBER} @{ROUTER} member.example")
        internal.execute(f"dig +time=2 +tries=1 -b {VPN_MEMBER} @{ROUTER} vpn.example")
        internal.execute(f"dig +time=2 +tries=1 -b {PLAIN} @{ROUTER} plain.example")
        # positive control, last in the capture: a member's query sent after the others'
        internal.execute(f"dig +time=2 +tries=1 -b {MEMBER} @{ROUTER} control.example")
        luca_router.wait_until_succeeds("tcpdump -n -A -r /tmp/tor-dns.pcap 2>/dev/null | grep -q control.example", timeout=20)
        tor_dns = capture_stop(luca_router, "/tmp/tor-dns.pcap", "-A")
        assert "member.example" in tor_dns, tor_dns
        assert "vpn.example" not in tor_dns and "plain.example" not in tor_dns, tor_dns
        got = internal.succeed(f"dig +short +time=3 -b {MEMBER} @{ROUTER} grafana.${net.domain}").strip()
        assert got == "${ip "100"}", f"the split horizon answered the member {got!r}"
  '';
}
