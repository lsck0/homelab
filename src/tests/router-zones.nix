# lab-wide: the policy between every zone (tests/lib/zones.py), across the real router
# the real router (instances/core/300-router/main.nix) between the house, the internet and the three zones: every flow across
# it against the policy as tests/lib/zones.py states it, its own services, the port forwards, the split horizon,
# dhcp, the vpn exit's killswitch, dns and failover, the refusals' counters, anti-spoofing, the wan limits, and no
# window while it reloads or boots
#
# One node per network, each owning the addresses the policy names (lab.multi): `house` (the fritzbox, the
# workstation, proxmox, another device, two internet clients, one inside cloudflare), `internal`, `dmz`, `apps`. Every
# probe that must fail has its positive control in the same plan: the same listener reached from an allowed source.
# What cannot run here: proxmox's own ip filter, which binds a guest to its address inside a zone (lib.tf `ipfilter`);
# a dmz guest claiming the edge's address on the dmz bridge is that layer's to stop, the router sees the edge.
{
  pkgs,
  lib,
  specialArgs,
  seed ? 1,
  ...
}:
let
  # a fixture app whose tcp route takes a wildcard host, which no route of the lab has yet. Its http
  # route keeps the zone's own name (demo.<domain>) in the hosts file, so the templates must fall through to reach it.
  wildcardApp = {
    enable = true;
    repo = "lsck0/demo";
    branch = "master";
    routes = {
      demo = {
        service = "web";
        targetPort = 8000;
        port = 20130;
      };
      demo-game = {
        service = "web";
        targetPort = 8001;
        protocol = "tcp";
        publicPort = 25566;
        port = 20131;
        host = "*.demo";
      };
    };
  };
  lab = import ./lib/lab.nix {
    inherit pkgs lib specialArgs;
    apps = folders: folders // { demo = wildcardApp; };
  };
  net = import ../modules/net.nix {
    inherit lib;
    inherit (specialArgs) inventory site;
  };
  inherit (lab) vlans;
  # teamspeak's guest is parked in the real lab, which drops its forwards; here it stands for every forwarded route
  inventory = lab.inventory // {
    "215" = lab.inventory."215" // {
      powered = true;
    };
  };

  ip = id: lab.inventory.${id}.ip;
  routerWan = net.wan.address;
  house = {
    fritzbox = net.wan.gateway;
    inherit (net.wan) workstation proxmox;
    device = "192.168.178.50";
    internet = "198.51.100.7";
    cloudflare = "104.16.0.10";
  };
  # a second server for the vpn exit, which answers as little as the first one here
  spareExit = {
    publicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    endpoint = "198.51.100.9:51820";
  };
  # the house's public address, the source a house client hairpinned through the fritzbox arrives from
  housePublic = "198.51.100.8";
  zoneAddresses = {
    internal = map ip [
      "100"
      "101"
      "102"
      "103"
      "104"
      "107"
      "111"
      "112"
      "113"
      "120"
      "121"
    ];
    external = map ip [
      "200"
      "201"
      "210"
      "211"
      "212"
      "213"
      "215"
    ];
    apps = map (id: ip (toString id)) lab.appsCatalog.swarm.workers;
  };

  facts = {
    nasClients = lib.attrNames lab.nasClients;
    # the edge's way to the workers: the public http routes of the shared swarm's apps
    appsPorts = lib.unique (map (r: r.port) (lib.filter (r: r.app != null) (lib.attrValues lab.catalog.external)));
    vpnMembers = map (e: ip (toString e.vmid)) (lib.filter (e: e.via == "vpn") (lib.attrValues lab.egress));
    appsNodes = zoneAddresses.apps;
    stateWorker = ip lab.catalog.swarm.stateId;
    # the dashboard's widgets that query a backend outside its zone (modules/flows.nix widgetGrants)
    dashboardWidgets =
      map
        (r: [
          (ip (toString r.vmid))
          r.port
        ])
        (
          lib.filter (r: (net.zoneOf (toString r.vmid)).name != "internal") (
            map (c: lab.specialArgs.lab.routes.${c.route}) (
              lib.filter (c: c.widget != null && c.widget.url == null) lab.specialArgs.lab.homepage
            )
          )
        );
  };
  inherit (net.zones.external) dhcpPool;
  # the split horizon serves the catalog: every route's name at its ingress, the enabled apps' public and internal
  # hosts with them, a forwarded route's name at its running guest (once, whatever its routes)
  dnsExpected = lib.listToAttrs (
    map (h: lib.nameValuePair (net.fqdn h) (ip "100")) (map (r: r.host) (lib.attrValues lab.catalog.internal))
    ++ map (h: lib.nameValuePair (net.fqdn h) (ip "200")) (map (r: r.host) (lib.attrValues lab.catalog.external))
    ++
      map (r: lib.nameValuePair (net.fqdn r.host) (ip (toString r.vmid)))
        # a wildcard host is no name of its own: the names below it are asserted by the wildcard subtests instead
        (
          lib.filter (r: r.vmid != null && !(lib.hasPrefix "*." r.host) && inventory.${toString r.vmid}.powered) (
            lib.attrValues lab.catalog.forwarded
          )
        )
    ++ [ (lib.nameValuePair (net.fqdn "smb") (ip "104")) ]
  );

  # a forwarded udp and tcp route of one guest: teamspeak's voice and file transfer, vm-215 a dmz address here
  voice = lab.catalog.forwarded.teamspeak;
  files = lab.catalog.forwarded.teamspeak-files;
  # the fixture's wildcard forward: the name one label below it, and the backends it answers with
  wildcardName = net.fqdn "one.demo";
  wildcardAddresses = lib.sort (a: b: a < b) lab.catalog.forwarded.demo-game.nodes;
  # the ports the policy names, and 4444, which only the killswitch subtest uses
  killswitchPort = 4444;
  tcpPorts = [
    22
    53
    80
    111
    443
    2049
    2377
    3100
    3102
    4040
    4317
    4318
    4319
    7946
    8006
    8095
    9055
    9100
    19532
    25565
    killswitchPort
  ]
  ++ [ files.publicPort ]
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
  udpPorts = [
    53
    111
    2049
    4789
    7946
    voice.publicPort
  ];

  tools = {
    environment.systemPackages = [
      pkgs.dig
      pkgs.netcat
      pkgs.tcpdump
      pkgs.python3
      pkgs.busybox
      pkgs.nftables
    ];
  };
  zoneNode = zone: extra: {
    imports = [
      (lab.multi {
        vlan = vlans.${zone};
        addresses = map (a: "${a}/24") zoneAddresses.${zone};
        gateway = net.zones.${zone}.routerIp;
      })
      tools
      extra
    ];
  };
  # a second nic on the zone's vlan, unaddressed, for a dhcp client
  dhcpNic = vlan: {
    virtualisation.vlans = lib.mkForce [
      vlan
      vlan
    ];
    networking.interfaces.eth2.ipv4.addresses = lib.mkForce [ ];
  };
  # prints the address a lease offers
  leaseScript = pkgs.writeShellScript "lease" ''[ "$1" = bound ] && echo "lease $ip router $router dns $dns"; exit 0'';
in
pkgs.testers.runNixOSTest {
  name = "router-zones";
  passthru.regressionSeeds = [ ];
  node.specialArgs = lab.specialArgs // {
    inherit inventory;
  };

  nodes.luca-router = {
    imports = [
      lab.router
      tools
    ];
    virtualisation.memorySize = 1024;
    homelab.egress.vpn.servers = lib.mkAfter [ spareExit ];
  };
  nodes.house = {
    imports = [
      (lab.multi {
        vlan = vlans.lan;
        addresses =
          map (a: "${a}/24") [
            house.fritzbox
            house.workstation
            house.proxmox
            house.device
            house.internet
            housePublic
          ]
          ++ [ "${house.cloudflare}/13" ];
        routes = [
          {
            address = "10.0.0.0";
            prefixLength = 8;
            via = routerWan;
          }
        ];
      })
      tools
    ];
  };
  nodes.internal = zoneNode "internal" { };
  nodes.dmz = zoneNode "external" (dhcpNic vlans.external);
  nodes.apps = zoneNode "apps" (dhcpNic vlans.apps);

  testScript =
    lab.driverPython
    + builtins.readFile ./lib/zones.py
    + ''
      import ipaddress
      import random
      import re

      SEED = ${toString seed}
      print(f"seed={SEED}")
      rng = random.Random(SEED)

      FACTS = json.loads('${builtins.toJSON facts}')
      DNS = json.loads('${builtins.toJSON dnsExpected}')
      ROUTER_WAN = "${routerWan}"
      HOUSE = json.loads('${builtins.toJSON house}')
      HOUSE_PUBLIC = "${housePublic}"
      ZONES = json.loads('${builtins.toJSON zoneAddresses}')
      LEGS = json.loads('${builtins.toJSON (lib.mapAttrs (zone: _: net.zones.${zone}.routerIp) zoneAddresses)}')
      POOL = (ipaddress.IPv4Address("${dhcpPool.first}"), ipaddress.IPv4Address("${dhcpPool.last}"))
      ORACLE = ZoneOracle(FACTS)
      # three high ports the policy never names, a fresh sample per seed
      TCP = sorted(set(${builtins.toJSON tcpPorts}) | set(rng.sample(range(30000, 60000), 3)))
      UDP = ${builtins.toJSON udpPorts}

      machines_by_address = {a: house for a in HOUSE.values()}
      for zone, machine in (("internal", internal), ("external", dmz), ("apps", apps)):
          machines_by_address.update({a: machine for a in ZONES[zone]})

      # esp has no ports: conntrack tracks it per address pair only, so an earlier esp probe decides a later one. A
      # reverse pair the policy opens admits the probe as its reply, and masquerade cannot tell two guests' esp to one
      # destination apart. Those probes depend on the shuffled order; every other esp probe is the policy's own.
      def esp_order_free(src, dst, seen):
          return seen in (None, src) and ORACLE.forward(dst, src, "esp", 0)[0] == "closed"

      def reach(machine, src, dst, port):
          return machine.execute(f"nc -z -w 2 -s {src} {dst} {port}")[0] == 0

      # a capture counts only once tcpdump listens; packet-buffered, so a read sees every packet so far
      def capture_start(machine, interface, pcap, bpf):
          machine.succeed(f"tcpdump -n -U -i {interface} -w {pcap} '{bpf}' > {pcap}.log 2>&1 & echo $! > {pcap}.pid")
          machine.wait_until_succeeds(f"grep -q 'listening on' {pcap}.log", timeout=30)

      def capture_read(machine, pcap):
          return machine.succeed(f"tcpdump -n -r {pcap} 2>/dev/null")

      def capture_stop(machine, pcap):
          machine.succeed(f"kill -INT $(cat {pcap}.pid)")
          machine.wait_until_fails(f"kill -0 $(cat {pcap}.pid)", timeout=30)
          return capture_read(machine, pcap)

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

      with subtest("the public address forwards https to the edge, from the internet and the house only"):
          plan = [
              {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
              {"src": HOUSE["cloudflare"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
              {"src": HOUSE["device"], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "open"},
              # a zone reaching the public address would be a way around its isolation; the lab calls the edge itself
              {"src": ZONES["internal"][1], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "closed"},
              {"src": ZONES["external"][1], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "closed"},
              {"src": ZONES["apps"][0], "dst": ROUTER_WAN, "proto": "tcp", "port": 443, "expect": "closed"},
              # a udp and a tcp route forwarded straight to their guest
              {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "udp", "port": ${toString voice.publicPort}, "expect": "open"},
              {"src": HOUSE["internet"], "dst": ROUTER_WAN, "proto": "tcp", "port": ${toString files.publicPort}, "expect": "open"},
              # minecraft's guest is no node here: its forward finds no one; and nothing else is forwarded
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
              (internal, ZONES["internal"][1], "10.100.0.1", 9100, False), (internal, "${ip "103"}", "10.100.0.1", 9100, True),
              (internal, ZONES["internal"][1], "10.100.0.1", 9055, False), (internal, "${ip "121"}", "10.100.0.1", 9055, True),
              (dmz, ZONES["external"][1], "10.200.0.1", 53, True), (dmz, ZONES["external"][1], "10.200.0.1", 22, False),
              (dmz, ZONES["external"][1], "10.200.0.1", 9100, False),
              (apps, ZONES["apps"][0], "10.250.0.1", 53, True), (apps, ZONES["apps"][0], "10.250.0.1", 22, False),
              # another interface's address does not open another interface's services
              (apps, ZONES["apps"][0], "10.100.0.1", 22, False), (dmz, ZONES["external"][1], "10.100.0.1", 53, False),
          ]
          wrong = [c[1:] for c in cases if reach(*c[:4]) != c[4]]
          assert not wrong, f"router services: (src, dst, port, expected) wrong for {wrong}"

      with subtest("the bastion reaches every zone's ssh from its leg there, the source each guest's recovery path admits"):
          for zone in ZONES:
              leg = LEGS[zone]
              assert reach(luca_router, leg, ZONES[zone][0], 22), f"the router's {leg} reaches no ssh in {zone}"

      with subtest("the split horizon answers from the catalog in every zone and the house, ipv4 alone"):
          for machine, src, server in ((internal, ZONES["internal"][1], "10.100.0.1"), (dmz, ZONES["external"][1], "10.200.0.1"),
                                       (apps, ZONES["apps"][0], "10.250.0.1"), (house, HOUSE["device"], ROUTER_WAN)):
              for name, address in DNS.items():
                  got = machine.succeed(f"dig +short +time=3 -b {src} @{server} {name}").strip()
                  assert got == address, f"{name} from {src}: {got!r}, expected {address}"
                  # a public name's proxied AAAA would send the house around the edge's own address
                  got = machine.succeed(f"dig +short +time=3 -b {src} @{server} AAAA {name}").strip()
                  assert not got, f"{name} AAAA from {src}: {got!r}"
          # retired names are gone; a name asked of the offline upstream times out, and dig's ';;' note is no answer
          internal.fail("dig +short +time=3 @10.100.0.1 tor.${net.domain} | grep -qv '^;'")
          # a forwarded route's srv record names its public port
          internal.succeed("dig +short +time=3 @10.100.0.1 SRV ${voice.srv}.${net.fqdn voice.host} | grep -qx '0 0 ${toString voice.publicPort} ${net.fqdn voice.host}.'")

      with subtest("a wildcard forward answers every name one label below it"):
          for machine, src, server in ((internal, ZONES["internal"][1], "10.100.0.1"), (dmz, ZONES["external"][1], "10.200.0.1"),
                                       (apps, ZONES["apps"][0], "10.250.0.1"), (house, HOUSE["device"], ROUTER_WAN)):
              addresses = sorted(machine.succeed(f"dig +short +time=3 -b {src} @{server} ${wildcardName}").split())
              assert addresses == ${builtins.toJSON wildcardAddresses}, f"${wildcardName} from {src}: {addresses!r}"
              # nodata, as the hosts plugin gives an exact name: no AAAA, and no question for blocky either
              answer = machine.succeed(f"dig +time=3 -b {src} @{server} AAAA ${wildcardName}")
              assert "status: NOERROR" in answer and "ANSWER: 0" in answer, f"${wildcardName} AAAA from {src}: {answer}"
          # the templates fall through: the zone's own name is still the hosts file's, at the edge
          assert internal.succeed("dig +short +time=3 @10.100.0.1 ${net.fqdn "demo"}").strip() == "${ip "200"}"
          # a name two labels below is below no wildcard, and no hosts line carries the wildcard itself
          internal.fail("dig +short +time=3 @10.100.0.1 a.${wildcardName} | grep -qv '^;'")
          internal.fail("dig +short +time=3 @10.100.0.1 '${net.fqdn "*.demo"}' | grep -qv '^;'")
          # outside the lab the same name is cloudflare's, raw: a proxied record would hide the game port
          records = json.loads(luca_router.succeed("cat $(systemctl show -P Environment ddns-cloudflare | tr ' ' '\\n' | sed -n 's/^DDNS_RECORDS=//p')"))
          assert {"name": "${net.fqdn "*.demo"}", "proxied": False} in records, records

      with subtest("every minecraft server answers at its own name below *.mc"):
          for name in ("cobblemon.mc.${net.domain}", "atm10.mc.${net.domain}"):
              assert internal.succeed(f"dig +short +time=3 @10.100.0.1 {name}").strip() == "${ip "214"}", name
          # the protocol's srv record is gone: its target would be the one address every client sends instead
          internal.fail("dig +short +time=3 @10.100.0.1 SRV _minecraft._tcp.mc.${net.domain} | grep -qv '^;'")

      with subtest("the house's v6 prefix is served by name to the v4-only lab, beside its v4 address"):
          prefix_name = "${net.fqdn net.wan.publicPrefixHost}"
          luca_router.succeed(f"echo '2001:db8:42:100:: {prefix_name}' > /run/public-address/prefix6")
          internal.wait_until_succeeds(f"[ \"$(dig +short +time=3 @10.100.0.1 AAAA {prefix_name})\" = 2001:db8:42:100:: ]", timeout=30)
          # its own zone shadows nothing of the lab domain's
          assert internal.succeed("dig +short +time=3 @10.100.0.1 grafana.${net.domain}").strip() == "${ip "100"}"

      with subtest("third parties down: the public address and the deny lists stay, no third party's unit fails"):
          published = "${net.fqdn net.wan.publicHost}"
          luca_router.succeed(f"echo '203.0.113.77 {published}' > /run/public-address/hosts")
          internal.wait_until_succeeds(f"[ \"$(dig +short +time=3 @10.100.0.1 {published})\" = 203.0.113.77 ]", timeout=30)
          luca_router.succeed("echo '0.0.0.0 kept.lab.test' > /var/lib/blocklists/hagezi-pro")
          luca_router.succeed("systemctl set-environment UPSTREAM_BACKOFF_S=0")
          # no fritzbox answers upnp here: the run fails and the last published address stays
          luca_router.fail("systemctl start public-address")
          # each unit and the upstream it gives up on (modules/upstream says "<name> unavailable" before its exit)
          given_up = (("ddns-cloudflare", "cloudflare"), ("blocklists-fetch", "githubusercontent"))
          for unit, upstream in given_up:
              luca_router.succeed(f"systemctl start {unit}")
              luca_router.wait_until_succeeds(f"systemctl show -P ActiveState {unit} | grep -qx inactive", timeout=300)
              result = luca_router.succeed(f"systemctl show -P Result {unit}").strip()
              assert result == "success", f"{unit}: {result}"
              luca_router.succeed(f"journalctl -b -u {unit} | grep -q ': {upstream} unavailable'")
          luca_router.succeed("systemctl unset-environment UPSTREAM_BACKOFF_S")
          assert luca_router.succeed("cat /run/public-address/hosts").split()[0] == "203.0.113.77"
          luca_router.succeed("grep -q kept.lab.test /var/lib/blocklists/hagezi-pro")
          assert internal.succeed(f"dig +short +time=3 @10.100.0.1 {published}").strip() == "203.0.113.77"

      with subtest("dhcp leases in the dmz's pool, never in the apps zone"):
          dmz.succeed("ip link set eth2 up")
          apps.succeed("ip link set eth2 up")
          out = dmz.succeed("busybox udhcpc -i eth2 -n -q -t 5 -s ${leaseScript}")
          lease = re.search(r"lease (\S+) router (\S+) dns (\S+)", out)
          assert lease and POOL[0] <= ipaddress.IPv4Address(lease.group(1)) <= POOL[1] and lease.group(2) == "10.200.0.1", out
          apps.fail("busybox udhcpc -i eth2 -n -q -t 3 -s ${leaseScript}")

      with subtest("vpn members never leave through the house, whichever piece of the exit is missing"):
          member, other = "${ip "120"}", ZONES["internal"][1]
          capture_start(house, "eth1", "/tmp/leak.pcap", "tcp port ${toString killswitchPort}")
          steps = ["true", "systemctl stop wireguard-wg-egress", "ip rule del fwmark 1 table 100"]
          for step in steps:
              luca_router.succeed(step)
              internal.fail(f"nc -z -w 2 -s {member} {HOUSE['internet']} ${toString killswitchPort}")
          assert counter("egress", "killswitch", "drop") > 0, "the killswitch saw nothing once the rule was gone"
          # inside the capture: a non-member's connection out through the house, which the capture must see
          internal.succeed(f"nc -z -w 2 -s {other} {HOUSE['cloudflare']} ${toString killswitchPort}")
          house.wait_until_succeeds(f"tcpdump -n -r /tmp/leak.pcap 2>/dev/null | grep -q '> {HOUSE['cloudflare']}.${toString killswitchPort}:'", timeout=10)
          leak = [l for l in capture_stop(house, "/tmp/leak.pcap").splitlines() if f"{HOUSE['cloudflare']}.${toString killswitchPort}" not in l]
          assert not leak, "a member's connection left through the house:\n" + "\n".join(leak)
          # positive control: a non-member reaches the same listener, masqueraded
          probe_check([{"src": other, "dst": HOUSE["internet"], "proto": "tcp", "port": ${toString killswitchPort}, "expect": "open",
                        "seen_src": ROUTER_WAN}], sources=machines_by_address, sinks=[house], seed=SEED)
          luca_router.succeed("systemctl restart egress-policy wireguard-wg-egress")
          luca_router.succeed("ip rule | grep -q 'fwmark 0x1 lookup 100'")

      with subtest("vpn members' dns goes into the tunnel, everyone else's to blocky, nobody's through the house"):
          capture_start(house, "eth1", "/tmp/dns-leak.pcap", "udp port 53")
          capture_start(luca_router, "wg-egress", "/tmp/tunnel-dns.pcap", "udp port 53")
          internal.execute("dig +time=2 +tries=1 -b ${ip "120"} @10.100.0.1 example.org")
          luca_router.wait_until_succeeds("tcpdump -n -r /tmp/tunnel-dns.pcap 2>/dev/null | grep -q example.org", timeout=20)
          # a split horizon name still answers for a member
          assert internal.succeed("dig +short +time=3 -b ${ip "120"} @10.100.0.1 grafana.${net.domain}").strip() == "${ip "100"}"
          internal.execute(f"dig +time=2 +tries=1 -b {other} @10.100.0.1 example.net")
          # positive control, last in the capture: the tunnel capture sees a member's query sent after the other's
          internal.execute("dig +time=2 +tries=1 -b ${ip "120"} @10.100.0.1 control.example")
          luca_router.wait_until_succeeds("tcpdump -n -r /tmp/tunnel-dns.pcap 2>/dev/null | grep -q control.example", timeout=20)
          tunnel = capture_stop(luca_router, "/tmp/tunnel-dns.pcap")
          assert "example.net" not in tunnel, tunnel
          # inside the house capture: a query to a house address, which the capture must see
          internal.execute(f"dig +time=1 +tries=1 -b {other} @{HOUSE['internet']} control.example")
          house.wait_until_succeeds(f"tcpdump -n -r /tmp/dns-leak.pcap 2>/dev/null | grep -q '> {HOUSE['internet']}.53:'", timeout=10)
          leak = [l for l in capture_stop(house, "/tmp/dns-leak.pcap").splitlines() if f"{HOUSE['internet']}.53" not in l]
          assert not leak, "a dns query left through the house:\n" + "\n".join(leak)

      with subtest("a refusal between the networks is counted by its source network and logged"):
          luca_router.succeed("systemctl start forward-deny-textfile")
          denied = luca_router.succeed("cat /var/lib/node-exporter-textfile/forward-deny.prom")
          refused = re.search(r'homelab_forward_denied_packets_total\{network="external"\} (\d+)', denied)
          assert refused and int(refused.group(1)) > 0, denied
          luca_router.succeed("journalctl -k | grep -q 'fwd-deny external: '")

      with subtest("the dashboard pings the house's frame, no other guest does"):
          internal.succeed("ping -c 1 -W 2 -I ${ip "102"} ${house.proxmox}")
          internal.succeed("ping -c 1 -W 2 -I ${ip "102"} ${house.fritzbox}")
          internal.fail("ping -c 1 -W 2 -I ${ip "101"} ${house.proxmox}")

      with subtest("an exit server without a handshake gives way to the next, its age a gauge"):
          luca_router.succeed("systemctl start wg-egress-failover")
          assert luca_router.succeed("wg show wg-egress endpoints").split()[1] == "${spareExit.endpoint}"
          age = luca_router.succeed("sed -n 's/^homelab_vpn_handshake_age_seconds //p' /var/lib/node-exporter-textfile/vpn_handshake.prom")
          assert int(age) > 180, age

      with subtest("a source never arrives on another network's interface"):
          before = counter("antispoof", "prerouting", "${net.zones.external.interface}")
          dmz.succeed("ip addr add 10.100.0.199/32 dev eth1")
          assert not reach(dmz, "10.100.0.199", "10.200.0.1", 53)
          assert counter("antispoof", "prerouting", "${net.zones.external.interface}") > before
          assert reach(dmz, ZONES["external"][1], "10.200.0.1", 53)
          house.succeed("ip addr add 10.100.0.198/32 dev eth1")
          assert not reach(house, "10.100.0.198", ZONES["external"][1], TCP[0])
          assert reach(house, HOUSE["device"], ZONES["external"][1], TCP[0])

      with subtest("nat's blanket accept toward the wan comes after every drop of the policy"):
          rules = [l.strip() for l in luca_router.succeed("nft list chain inet nixos-fw forward-allow").splitlines()]
          nat = max(i for i, l in enumerate(rules) if 'oifname "${net.wan.interface}" accept' in l and "comment" in l)
          last_drop = max(i for i, l in enumerate(rules) if l.endswith("drop"))
          assert last_drop < nat, rules

      with subtest("an internet source flooding syns is metered, the house, hairpinned or not, and cloudflare are not"):
          luca_router.succeed(f"echo '{HOUSE_PUBLIC} ${net.fqdn net.wan.publicHost}' > /run/public-address/hosts")
          luca_router.wait_until_succeeds(f"nft list set ip wan-limits house_public | grep -q {HOUSE_PUBLIC}", timeout=30)
          # a reload empties the set and fills it again
          luca_router.succeed("systemctl reload nftables")
          luca_router.succeed(f"nft list set ip wan-limits house_public | grep -q {HOUSE_PUBLIC}")
          for src, metered in ((HOUSE["device"], False), (HOUSE_PUBLIC, False), (HOUSE["cloudflare"], False), (HOUSE["internet"], True)):
              before = counter("wan-limits", "prerouting", "wan-syn")
              house.succeed(f"${synFlood} {src} {ROUTER_WAN} 443 ${toString synFloodCount}")
              grew = counter("wan-limits", "prerouting", "wan-syn") > before
              assert grew == metered, f"{src}: wan-syn grew {grew}, expected {metered}"

      with subtest("no forbidden flow opens while the ruleset reloads or the router boots"):
          loop = (f"for i in $(seq 300); do echo try; nc -z -w 1 -s {ZONES['external'][1]} ${ip "104"} 2049 && echo OPEN; done "
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
          if "${ip "212"}" in FACTS["nasClients"]:
              assert reach(dmz, "${ip "212"}", "${ip "104"}", 2049)
    '';
}
