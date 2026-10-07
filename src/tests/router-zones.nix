# lab-wide: the policy between every zone (tests/lib/zones.py), across the real router
# the real router (instances/300-router/main.nix) between the house, the internet and the three zones: every flow across
# it against the policy as tests/lib/zones.py states it, its own services, the port forwards, the split horizon,
# dhcp, the vpn exit's killswitch and dns, anti-spoofing, the wan limits, and no window while it reloads or boots
#
# One node per network, each owning the addresses the policy names (lab.multi): `house` (the fritzbox, the
# workstation, proxmox, another device, two internet clients, one inside cloudflare), `internal`, `dmz`, `apps`. Every
# probe that must fail has its positive control in the same plan: the same listener reached from an allowed source.
# What cannot run here: proxmox's own ip filter, which binds a guest to its address inside a zone (lib.tf FIREWALL);
# a dmz guest claiming the edge's address on the dmz bridge is that layer's to stop, the router sees the edge.
{ pkgs, lib, specialArgs, seed ? 1, ... }:
let
  lab = import ./lib/lab.nix { inherit pkgs lib specialArgs; };
  net = import ../modules/net.nix { inherit lib; inherit (specialArgs) inventory site; };
  inherit (lab) vlans;

  ip = id: lab.inventory.${id}.ip;
  routerWan = net.wan.address;
  house = {
    fritzbox = net.wan.gateway;
    workstation = net.wan.workstation;
    proxmox = net.wan.proxmox;
    device = "192.168.178.50";
    internet = "198.51.100.7";
    cloudflare = "104.16.0.10";
  };
  zoneAddresses = {
    internal = map ip [ "100" "101" "105" "109" "112" "117" "130" "140" ];
    dmz = map ip [ "200" "203" "204" "206" "207" "210" ];
    apps = map ip [ "250" "251" "252" ];
  };

  facts = {
    nasClients = lib.attrNames lab.nasClients;
    appsPorts = lab.catalog.ports.external;
    vpnMembers = map (e: ip (toString e.vmid)) (lib.attrValues lab.egress);
    appsNodes = zoneAddresses.apps;
  };
  # the split horizon serves the catalog: every route's name at its ingress, the enabled apps' public and internal
  # hosts with them
  dnsExpected = lib.listToAttrs (
    map (h: lib.nameValuePair (net.fqdn h) (ip "100"))
      (map (r: r.host) (lib.attrValues lab.catalog.internal))
    ++ map (h: lib.nameValuePair (net.fqdn h) (ip "200"))
      (map (r: r.host) (lib.attrValues lab.catalog.external))
    ++ [ (lib.nameValuePair (net.fqdn "smb") (ip "109")) ]);

  # the ports the policy names, and 4444, which only the killswitch subtest uses
  killswitchPort = 4444;
  tcpPorts = [ 22 53 80 111 443 2049 2377 3100 4040 4317 4318 4319 7946 8006 8095 9055 9100 19532 25565 killswitchPort ]
    ++ facts.appsPorts;
  # count syns from one source at one address, as fast as the kernel sends them
  synFlood = pkgs.writers.writePython3 "syn-flood" { } ''
    import socket
    import sys

    src, dst = sys.argv[1], sys.argv[2]
    port, count = int(sys.argv[3]), int(sys.argv[4])
    sockets = []
    for _ in range(count):
        s = socket.socket()
        s.setblocking(False)
        s.bind((src, 0))
        try:
            s.connect((dst, port))
        except BlockingIOError:
            pass
        sockets.append(s)
  '';
  synFloodCount = 400;
  udpPorts = [ 53 111 2049 4789 7946 ];

  tools = { environment.systemPackages = [ pkgs.dig pkgs.netcat pkgs.tcpdump pkgs.python3 pkgs.busybox pkgs.nftables ]; };
  zoneNode = zone: vlan: extra: {
    imports = [ (lab.multi { inherit vlan; addresses = map (a: "${a}/24") zoneAddresses.${zone}; gateway = net.zones.${zone'.${zone}}.routerIp; }) tools extra ];
  };
  zone' = { internal = "internal"; dmz = "external"; apps = "apps"; };
  # a second nic on the zone's vlan, unaddressed, for a dhcp client
  dhcpNic = vlan: {
    virtualisation.vlans = lib.mkForce [ vlan vlan ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [ ];
  };
  # prints the address a lease offers
  leaseScript = pkgs.writeShellScript "lease" ''[ "$1" = bound ] && echo "lease $ip router $router dns $dns"; exit 0'';
in
pkgs.testers.runNixOSTest {
  name = "router-zones";
  passthru.regressionSeeds = [ ];
  node.specialArgs = lab.specialArgs;

  nodes.luca-router = { imports = [ lab.router tools ]; virtualisation.memorySize = 1024; };
  nodes.house = {
    imports = [ (lab.multi {
      vlan = vlans.lan;
      addresses = map (a: "${a}/24") [ house.fritzbox house.workstation house.proxmox house.device house.internet ]
        ++ [ "${house.cloudflare}/13" ];
      routes = [ { address = "10.0.0.0"; prefixLength = 8; via = routerWan; } ];
    }) tools ];
  };
  nodes.internal = zoneNode "internal" vlans.internal { };
  nodes.dmz = zoneNode "dmz" vlans.dmz (dhcpNic vlans.dmz);
  nodes.apps = zoneNode "apps" vlans.apps (dhcpNic vlans.apps);

  testScript = lab.driverPython + builtins.readFile ./lib/zones.py + ''
    import random
    import re

    SEED = ${toString seed}
    print(f"seed={SEED}")
    rng = random.Random(SEED)

    FACTS = json.loads('${builtins.toJSON facts}')
    DNS = json.loads('${builtins.toJSON dnsExpected}')
    ROUTER_WAN = "${routerWan}"
    HOUSE = json.loads('${builtins.toJSON house}')
    ZONES = json.loads('${builtins.toJSON zoneAddresses}')
    ORACLE = ZoneOracle(FACTS)
    # three high ports the policy never names, a fresh sample per seed
    TCP = sorted(set(${builtins.toJSON tcpPorts}) | set(rng.sample(range(30000, 60000), 3)))
    UDP = ${builtins.toJSON udpPorts}

    machines_by_address = {a: house for a in HOUSE.values()}
    for zone, machine in (("internal", internal), ("dmz", dmz), ("apps", apps)):
        machines_by_address.update({a: machine for a in ZONES[zone]})

    # esp has no ports: conntrack tracks it per address pair only, so an earlier esp probe decides a later one. A
    # reverse pair the policy opens admits the probe as its reply, and masquerade cannot tell two guests' esp to one
    # destination apart. Those probes depend on the shuffled order; every other esp probe is the policy's own.
    def esp_order_free(src, dst, seen):
        return seen in (None, src) and ORACLE.forward(dst, src, "esp", 0)[0] == "closed"

    def reach(machine, src, dst, port):
        return machine.execute(f"nc -z -w 2 -s {src} {dst} {port}")[0] == 0

    def counter(table, chain, marker):
        out = luca_router.succeed(f"nft list chain ip {table} {chain}")
        line = next(l for l in out.splitlines() if marker in l)
        return int(re.search(r"counter packets (\d+)", line).group(1))

    start_all()
    luca_router.wait_for_unit("multi-user.target")
    for machine in (house, internal, dmz, apps):
        machine.wait_for_unit("network.target")
    probe_sinks_start([house, internal, dmz, apps], tcp=tuple(TCP), udp=tuple(UDP), esp=True)

    with subtest("the router comes up offline with its whole policy"):
        luca_router.succeed("systemctl is-active nftables coredns blocky kea-dhcp4-server tor wireguard-wg0 wireguard-wg-egress egress-policy")

    with subtest("every flow across the router follows the policy"):
        plan = []
        senders = [a for a in machines_by_address if a != HOUSE["fritzbox"]]
        for src in senders:
            for dst in senders:
                if machines_by_address[src] is machines_by_address[dst]:
                    continue
                for proto, ports in (("tcp", TCP), ("udp", UDP), ("esp", [0])):
                    for port in ports:
                        expect, seen = ORACLE.forward(src, dst, proto, port)
                        if proto == "esp" and not esp_order_free(src, dst, seen):
                            continue
                        entry = {"src": src, "dst": dst, "proto": proto, "port": port, "expect": expect}
                        if seen is not None and seen != src:
                            entry["seen_src"] = seen
                        plan.append(entry)
        rng.shuffle(plan)
        probe_check(plan, sources=machines_by_address, sinks=[house, internal, dmz, apps], seed=SEED)

    with subtest("the public address forwards https to the edge, from the internet, the house and the trusted zones only"):
        plan = [
            {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
            {"src": HOUSE["cloudflare"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
            {"src": HOUSE["device"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
            {"src": ZONES["internal"][1], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
            # a dmz or the apps zone reaching the public address would be a way around its isolation
            {"src": ZONES["dmz"][1], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "closed"},
            {"src": ZONES["apps"][0], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "closed"},
            # minecraft's vm is disabled: no forward; and nothing else is forwarded
            {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "tcp", "port": 25565, "expect": "closed"},
            {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "tcp", "port": 80, "expect": "closed"},
        ]
        probe_check(plan, sources=machines_by_address, sinks=[dmz], seed=SEED)

    with subtest("the router's own services answer exactly who flows.nix lists"):
        cases = [
            (house, HOUSE["device"], ROUTER_WAN, 22, True), (house, HOUSE["device"], ROUTER_WAN, 53, True),
            (house, HOUSE["device"], ROUTER_WAN, 9100, False), (house, HOUSE["internet"], ROUTER_WAN, 22, False),
            (house, HOUSE["internet"], ROUTER_WAN, 53, False),
            (internal, ZONES["internal"][1], "10.100.0.1", 22, True), (internal, ZONES["internal"][1], "10.100.0.1", 53, True),
            (internal, ZONES["internal"][1], "10.100.0.1", 9100, False), (internal, "${ip "105"}", "10.100.0.1", 9100, True),
            (internal, ZONES["internal"][1], "10.100.0.1", 9055, False), (internal, "${ip "130"}", "10.100.0.1", 9055, True),
            (dmz, ZONES["dmz"][1], "10.200.0.1", 53, True), (dmz, ZONES["dmz"][1], "10.200.0.1", 22, False),
            (dmz, ZONES["dmz"][1], "10.200.0.1", 9100, False),
            (apps, ZONES["apps"][0], "10.250.0.1", 53, True), (apps, ZONES["apps"][0], "10.250.0.1", 22, False),
            # another interface's address does not open another interface's services
            (apps, ZONES["apps"][0], "10.100.0.1", 22, False), (dmz, ZONES["dmz"][1], "10.100.0.1", 53, False),
        ]
        wrong = [c[1:] for c in cases if reach(*c[:4]) != c[4]]
        assert not wrong, f"router services: (src, dst, port, expected) wrong for {wrong}"

    with subtest("the split horizon answers from the catalog in every zone"):
        for machine, src, server in ((internal, ZONES["internal"][1], "10.100.0.1"), (dmz, ZONES["dmz"][1], "10.200.0.1"),
                                     (apps, ZONES["apps"][0], "10.250.0.1")):
            for name, address in DNS.items():
                got = machine.succeed(f"dig +short +time=3 -b {src} @{server} {name}").strip()
                assert got == address, f"{name} from {src}: {got!r}, expected {address}"
        # retired and disabled names are gone
        internal.fail("dig +short +time=3 @10.100.0.1 tor.${net.domain} | grep -q .")
        internal.fail("dig +short +time=3 @10.100.0.1 mc.${net.domain} | grep -q .")

    with subtest("dhcp leases in the dmz's pool, never in the apps zone"):
        dmz.succeed("ip link set eth2 up")
        apps.succeed("ip link set eth2 up")
        out = dmz.succeed("busybox udhcpc -i eth2 -n -q -t 5 -s ${leaseScript}")
        lease = re.search(r"lease (\S+) router (\S+) dns (\S+)", out)
        assert lease and 211 <= int(lease.group(1).split(".")[3]) <= 254 and lease.group(2) == "10.200.0.1", out
        apps.fail("busybox udhcpc -i eth2 -n -q -t 3 -s ${leaseScript}")

    with subtest("vpn members never leave through the house, whichever piece of the exit is missing"):
        member, other = "${ip "112"}", ZONES["internal"][1]
        house.succeed("tcpdump -n -i eth1 -w /tmp/leak.pcap 'tcp port ${toString killswitchPort}' >/dev/null 2>&1 & sleep 1")
        steps = ["true", "systemctl stop wireguard-wg-egress", "ip rule del fwmark 1 table 100"]
        for step in steps:
            luca_router.succeed(step)
            internal.fail(f"nc -z -w 2 -s {member} {HOUSE['internet']} ${toString killswitchPort}")
        assert counter("egress", "killswitch", "drop") > 0, "the killswitch saw nothing once the rule was gone"
        # read before the positive control, whose connection leaves through the house by design
        house.succeed("pkill -INT -f leak.pcap; sleep 1")
        leak = house.succeed("tcpdump -n -r /tmp/leak.pcap 2>/dev/null")
        assert leak == "", f"a member's connection left through the house:\n{leak}"
        # positive control: a non-member reaches the same listener, masqueraded
        probe_check([{"src": other, "dst": HOUSE["internet"], "proto": "tcp", "port": ${toString killswitchPort}, "expect": "open",
                      "seen_src": ROUTER_WAN}], sources=machines_by_address, sinks=[house], seed=SEED)
        luca_router.succeed("systemctl restart egress-policy wireguard-wg-egress")
        luca_router.succeed("ip rule | grep -q 'fwmark 0x1 lookup 100'")

    with subtest("vpn members' dns goes into the tunnel, everyone else's to blocky, nobody's through the house"):
        house.succeed("tcpdump -n -i eth1 -w /tmp/dns-leak.pcap 'udp port 53' >/dev/null 2>&1 & sleep 1")
        luca_router.succeed("tcpdump -n -i wg-egress -c 1 'udp port 53' > /tmp/tunnel-dns 2>&1 &")
        internal.execute("dig +time=2 +tries=1 -b ${ip "112"} @10.100.0.1 example.org")
        luca_router.wait_until_succeeds("grep -q 'IP ' /tmp/tunnel-dns", timeout=20)
        # a split horizon name still answers for a member
        assert internal.succeed("dig +short +time=3 -b ${ip "112"} @10.100.0.1 grafana.${net.domain}").strip() == "${ip "100"}"
        luca_router.succeed("tcpdump -n -i wg-egress -w /tmp/tunnel-dns-other.pcap 'udp port 53' >/dev/null 2>&1 & sleep 1")
        internal.execute(f"dig +time=2 +tries=1 -b {other} @10.100.0.1 example.net")
        luca_router.succeed("sleep 3; pkill -INT -f tunnel-dns-other.pcap; sleep 1")
        # the member's own query above may still be retried into the tunnel (its exit is offline): count the other's name
        tunnel = luca_router.succeed("tcpdump -n -r /tmp/tunnel-dns-other.pcap 2>/dev/null")
        assert "example.net" not in tunnel, tunnel
        house.succeed("pkill -INT -f dns-leak.pcap; sleep 1")
        leak = house.succeed("tcpdump -n -r /tmp/dns-leak.pcap 2>/dev/null")
        assert leak == "", f"a dns query left through the house:\n{leak}"

    with subtest("a source never arrives on another network's interface"):
        before = counter("antispoof", "prerouting", "${net.zones.external.interface}")
        dmz.succeed("ip addr add 10.100.0.199/32 dev eth1")
        assert not reach(dmz, "10.100.0.199", "10.200.0.1", 53)
        assert counter("antispoof", "prerouting", "${net.zones.external.interface}") > before
        assert reach(dmz, ZONES["dmz"][1], "10.200.0.1", 53)
        house.succeed("ip addr add 10.100.0.198/32 dev eth1")
        assert not reach(house, "10.100.0.198", ZONES["dmz"][1], TCP[0])
        assert reach(house, HOUSE["device"], ZONES["dmz"][1], TCP[0])

    with subtest("nat's blanket accept toward the wan comes after every drop of the policy"):
        rules = [l.strip() for l in luca_router.succeed("nft list chain inet nixos-fw forward-allow").splitlines()]
        nat = max(i for i, l in enumerate(rules) if 'oifname "${net.wan.interface}" accept' in l and "comment" in l)
        last_drop = max(i for i, l in enumerate(rules) if l.endswith("drop"))
        assert last_drop < nat, rules

    with subtest("an internet source flooding syns is metered, the house and cloudflare are not"):
        for src, metered in ((HOUSE["device"], False), (HOUSE["cloudflare"], False), (HOUSE["internet"], True)):
            before = counter("wan-limits", "prerouting", "wan-syn")
            house.succeed(f"${synFlood} {src} {ROUTER_WAN} 443 ${toString synFloodCount}")
            grew = counter("wan-limits", "prerouting", "wan-syn") > before
            assert grew == metered, f"{src}: wan-syn grew {grew}, expected {metered}"

    with subtest("no forbidden flow opens while the ruleset reloads or the router boots"):
        loop = (f"for i in $(seq 300); do echo try; nc -z -w 1 -s {ZONES['dmz'][1]} ${ip "109"} 2049 && echo OPEN; done "
                "> /tmp/window.log 2>&1 &")
        dmz.succeed(loop)
        # ten restarts within a second pass systemd's start limit (5 in 10 s); reset-failed clears its count
        for _ in range(10):
            luca_router.succeed("systemctl reload nftables")
            luca_router.succeed("systemctl reset-failed nftables && systemctl restart nftables")
        luca_router.shutdown()
        luca_router.start()
        luca_router.wait_for_unit("multi-user.target")
        dmz.wait_until_succeeds("[ $(grep -c try /tmp/window.log) -ge 20 ]", timeout=120)
        dmz.fail("grep -q OPEN /tmp/window.log")
        # positive control: a nas client of the dmz reaches the same port
        if "${ip "206"}" in FACTS["nasClients"]:
            assert reach(dmz, "${ip "206"}", "${ip "109"}", 2049)
  '';
}
