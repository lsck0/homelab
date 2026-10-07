# a test's nas clients by address, from the evaluated configurations of its nodes: what a test nas exports
# (tests/lib/lab.nix `nas`); the lab itself exports what every instance.nix declares (lab.nasClients)
#
# configs: name -> an evaluated nixos `config`, the nas itself left out. A config counts when its hostName is vm-<id>
# of a powered inventory guest and it mounts at least one share (homelab.nasShares); anything else (the router, a
# test's stand-in nodes) is skipped:
#
#   nasClients = import ./modules/nas-clients.nix { inherit lib inventory; configs = nodes; };
#   # { "10.100.0.140" = [ { path = "/srv/nas/data/swarm-manager"; readOnly = false; mode = null; } ... ]; ... }
{ lib, inventory, configs }:
let
  vmOf = config: let match = builtins.match "vm-([0-9]+)" config.networking.hostName; in
    if match == null then null else inventory.${builtins.head match} or null;
  clients = lib.filter (config: let vm = vmOf config; in vm != null && vm.powered) (lib.attrValues configs);
  ips = map (config: (vmOf config).ip) clients;
in
assert lib.assertMsg (lib.allUnique ips) "nas-clients: two configurations claim one guest address";
lib.filterAttrs (_: shares: shares != [ ])
  (lib.listToAttrs (map (config: lib.nameValuePair (vmOf config).ip config.homelab.nasShares) clients))
