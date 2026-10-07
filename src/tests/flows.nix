# lab-wide: placement and exposure compose in modules/flows.nix
# an app on its own internal-zone guest serving an external route: the edge reaches the guest's published port and its
# controller (guard and router), as for the shared swarm
{ pkgs, lib, specialArgs, ... }:
let
  # a free vmid of the internal zone
  placedId = "199";
  port = 20180;
  apps = folders: folders // {
    inward = {
      enable = true;
      repo = "lsck0/inward";
      branch = "master";
      routes.inward = { inherit port; zone = "external"; off = { sso = "the fixture is public"; anubis = "no browser here"; }; };
      reservation = { memoryMiB = 512; cpus = 0.5; };
      placement = { zone = "internal"; vmid = lib.toInt placedId; vm.memoryMiB = 1536; };
    };
  };
  lab = (import ./lib/lab.nix { inherit pkgs lib specialArgs apps; }).specialArgs.lab;
  net = import ../modules/net.nix { inherit lib; inherit (lab) inventory site; };
  flows = import ../modules/flows.nix { inherit lib net lab; inherit (lab) inventory catalog nasClients; };
  edge = net.zones.external.ingress;

  # the edge's grant onto the guest's port, and its forward across the router
  granted = p: lib.any (g: g.to == placedId && lib.elem edge g.from && lib.elem p g.tcp) flows.guards;
  names = endpoint: id: lib.elem (net.ipOf id) (if endpoint.addresses == null then [ ] else endpoint.addresses);
  forwarded = p: lib.any (f: names f.from edge && names f.to placedId && lib.elem p (f.tcp or [ ])) flows.forward;

  cases = {
    route-grant = granted port;
    route-forward = forwarded port;
    controller-grant = granted lab.catalog.swarm.controllerPort;
    controller-forward = forwarded lab.catalog.swarm.controllerPort;
    # positive control: a port nothing grants
    unrelated-closed = !(granted (port + 1)) && !(forwarded (port + 1));
  };
  failed = lib.attrNames (lib.filterAttrs (_: holds: !holds) cases);
in
assert lib.assertMsg (failed == [ ]) "flows: an internal guest's external app route fails ${toString failed}";
pkgs.runCommand "flows" { } ''
  echo "flows: ${toString (lib.length (lib.attrNames cases))} cases hold" > $out
''
