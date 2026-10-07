# lab-wide: the harness itself (tests/lib/), which every vm test stands on
# the test harness itself (tests/lib/): the real router between two lab guests at their inventory addresses,
# labprobe checking a few flows its policy allows and denies, each denial with its positive control, and the
# offline dns path. The router's full matrix is router-zones; this keeps the harness honest in a few minutes.
{ pkgs, lib, specialArgs, seed ? 1, ... }:
let
  lab = import ./lib/lab.nix { inherit pkgs lib specialArgs; };

  internal = lab.inventory."121".ip;
  dmz = lab.inventory."203".ip;
  # the router's own address in the internal zone: an allowed source for the controls
  routerInternal = "10.100.0.1";
  # no service port of the sink guests: those are guarded to their ingress (modules/network.nix)
  sinkTcp = 18080;
  # what the router runs offline: firewall, dns, dhcp, tor, both tunnels and the egress policy
  routerUnits = [
    "nftables" "coredns" "blocky" "kea-dhcp4-server" "tor" "wireguard-wg0" "wireguard-wg-egress" "egress-policy"
  ];
  sinkUdp = 9999;

  # a lab guest that runs the sinks; its own firewall opens them, so a refusal is the router's
  sinkGuest = vmid: {
    imports = [ (lab.guest vmid { }) ];
    networking.firewall.allowedTCPPorts = [ sinkTcp ];
    networking.firewall.allowedUDPPorts = [ sinkUdp ];
    environment.systemPackages = [ pkgs.dig ];
  };
in
pkgs.testers.runNixOSTest {
  name = "harness-smoke";
  passthru.regressionSeeds = [ ];

  node.specialArgs = lab.specialArgs;
  nodes.luca-router = {
    imports = [ lab.router ];
    virtualisation.memorySize = 1024;
  };
  nodes.vm-121 = sinkGuest "121";
  nodes.vm-203 = sinkGuest "203";

  testScript = lab.driverPython + ''
    SEED = ${toString seed}
    print(f"seed={SEED}")

    start_all()
    luca_router.wait_for_unit("multi-user.target")
    with subtest("the router comes up offline: firewall, dns, dhcp, tor, both tunnels, the egress policy"):
        luca_router.succeed("systemctl is-active ${lib.concatStringsSep " " routerUnits}")

    vm_121.wait_for_unit("multi-user.target")
    vm_203.wait_for_unit("multi-user.target")
    probe_sinks_start([vm_121, vm_203], tcp=(${toString sinkTcp},), udp=(${toString sinkUdp},))

    with subtest("internal reaches the dmz; the dmz reaches no internal guest, which the router does reach"):
        router = "${routerInternal}"
        probe_check([
            {"src": "${internal}", "dst": "${dmz}", "proto": "tcp", "port": ${toString sinkTcp}, "expect": "open"},
            {"src": "${internal}", "dst": "${dmz}", "proto": "udp", "port": ${toString sinkUdp}, "expect": "open"},
            {"src": "${dmz}", "dst": "${internal}", "proto": "tcp", "port": ${toString sinkTcp}, "expect": "closed"},
            {"src": "${dmz}", "dst": "${internal}", "proto": "udp", "port": ${toString sinkUdp}, "expect": "closed"},
            {"src": router, "dst": "${internal}", "proto": "tcp", "port": ${toString sinkTcp}, "expect": "open"},
            {"src": router, "dst": "${internal}", "proto": "udp", "port": ${toString sinkUdp}, "expect": "open"},
        ], sources={"${internal}": vm_121, "${dmz}": vm_203, router: luca_router},
            sinks=[vm_121, vm_203], seed=SEED)

    with subtest("the split horizon answers from the catalog, blocky blocks from its local list"):
        vm_121.succeed("dig +short +time=3 @10.100.0.1 grafana.lsck0.dev | grep -qx 10.100.0.100")
        vm_203.succeed("dig +short +time=3 @10.200.0.1 hello.lsck0.dev | grep -qx 10.200.0.200")
        vm_121.succeed("dig +short +time=3 @10.100.0.1 blocked.lab.test | grep -qx 0.0.0.0")
  '';
}
