# every guest's nas mounts by address: what the NAS exports (109-internal-nas's lib/nas-exports.nix) and the router opens nfs to
#
# configs: name -> an evaluated nixos `config`, the NAS itself left out. A config counts when its hostName is
# vm-<id> of an inventory guest that is not switched off and it mounts at least one share (homelab.nasShares);
# anything else (the router, a test's stand-in nodes) is skipped. The flake calls it over its
# nixosConfigurations, a test over its nodes, so both export exactly what the guests mount:
#
#   nasClients = import ./modules/nas-clients.nix { inherit lib inventory; configs = { ... }; };
#   # { "10.100.0.140" = [ { path = "/srv/nas/data/swarm-manager"; readOnly = false; } ... ]; ... }
{ lib, inventory, configs }:
let
  vmOf = config: let match = builtins.match "vm-([0-9]+)" config.networking.hostName; in
    if match == null then null else inventory.${builtins.head match} or null;
  clients = lib.filter (config: let vm = vmOf config; in vm != null && vm.enabled != "false") (lib.attrValues configs);
  ips = map (config: (vmOf config).ip) clients;
in
assert lib.assertMsg (lib.allUnique ips) "nas-clients: two configurations claim one guest address";
lib.filterAttrs (_: shares: shares != [ ])
  (lib.listToAttrs (map (config: lib.nameValuePair (vmOf config).ip config.homelab.nasShares) clients))
