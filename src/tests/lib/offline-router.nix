# the real router (instances/300-router/main.nix) in a test vm without internet: lab.router imports it
#
# What changes is only what reaches out of the lab: the tunnels get real-format keys (the stub's test-<name>
# strings are no wireguard keys, and wireguard-wg-egress restarted thousands of times in a tight loop on them),
# the jobs that talk to cloudflare, proton and tor's control port stay off, and blocky blocks from a local list
# instead of downloading one. tor, blocky, coredns, kea, nftables, both tunnels and the egress policy run as in
# production.
{ lib, pkgs, ... }:
let
  secretValues = import ./secret-values.nix { inherit pkgs; };
  # a name a test can resolve to see blocky block: blocky answers 0.0.0.0
  denylist = pkgs.writeText "blocky-test-denylist" ''
    0.0.0.0 blocked.lab.test
  '';
in {
  testing.secretValues = { inherit (secretValues) wireguard-private-key protonvpn-private-key; };

  # internet-only work; a test starts a unit itself when it is about it
  systemd.timers = lib.genAttrs [ "ddns-cloudflare" "protonvpn-port" "tor-new-circuits" ]
    (_: { wantedBy = lib.mkForce [ ]; });

  services.blocky.settings.blocking.denylists.ads = lib.mkForce [ "${denylist}" ];
}
