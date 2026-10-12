# the real router (core/300-router/main.nix) in a test vm without internet: lab.router imports it
#
# What changes is only what reaches out of the lab: the tunnels and the onion routes get real-format keys (the stub's
# test-<name> strings are neither wireguard keys nor base64 seeds: wireguard-wg-egress restarted thousands of times in a
# tight loop on them, tor never started), the jobs that talk to cloudflare, proton and tor's control port stay off,
# and blocky blocks from a local list instead of downloading one. tor, blocky, coredns, kea, nftables, both tunnels
# and the egress policy run as in production.
{ config, lib, pkgs, ... }:
let
  secretValues = import ./secret-values.nix { inherit pkgs; };
  service = import ../../modules/service.nix { inherit lib; };
  # a name a test can resolve to see blocky block: blocky answers 0.0.0.0
  denylist = pkgs.writeText "blocky-test-denylist" ''
    0.0.0.0 blocked.lab.test
  '';
in {
  # an onion route's key is a seed of its own (lib/onion-services.nix), which a test may replace by one it knows
  testing.secretValues = { inherit (secretValues) wireguard-private-key protonvpn-private-key; }
    // lib.mapAttrs' (name: _: lib.nameValuePair (service.onionKeyOf name) (lib.mkDefault (secretValues.onionSeedOf name)))
      config.services.tor.relay.onionServices;

  # internet-only work; a test starts a unit itself when it is about it
  systemd.timers = lib.genAttrs [ "public-address" "public-prefix" "blocklists-fetch" "protonvpn-port" "tor-new-circuits" ]
    (_: { wantedBy = lib.mkForce [ ]; });

  services.blocky.settings.blocking.denylists.ads = lib.mkForce [ "${denylist}" ];
}
