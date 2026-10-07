# the guests against what they declare and what the node holds
#
# - a guest's declared needs (instance.nix `vm.needs`) are what its configuration uses, so the kind the rule derives
#   from them (modules/instance-schema.nix) is the kind it must be: its own container runtime, nfs (client or server)
# - host memory budget: every powered guest's floor (a vm's balloon floor, its whole memory when unballooned, an
#   lxc's limit) plus the zfs arc and the node's reserve fit the node's memory (src/lab/node.nix). Past it the
#   balloon squeezes guests below their floors and the node swaps; onDemand guests count, since all may wake at once.
{ lib, configs, lab, ... }:
let
  node = import ../../lab/node.nix;
  # the largest floors, named in the violation: where shrinking pays
  largestShown = 8;

  usesOf = c: lib.optional (c.virtualisation.podman.enable || c.virtualisation.docker.enable
      || c.virtualisation.oci-containers.containers != { } || (c.homelab.rootlessDocker or { }) != { }) "containers"
    ++ lib.optional (c.homelab.nasShares != [ ] || c.services.nfs.server.enable) "nfs";
  needsLaws = lib.concatLists (lib.mapAttrsToList (name: host:
    let
      declared = lib.sort lib.lessThan lab.instances.${host.id}.config.vm.needs;
      used = usesOf configs.${name};
    in
    lib.optional (host.id != "300" && declared != used)
      "${name}: vm.needs is [ ${toString declared} ], its configuration uses [ ${toString used} ]"
  ) lab.hosts);

  floorOf = vm: if vm.guestKind == "lxc" || vm.balloonMiB == 0 then vm.memoryMiB else vm.balloonMiB;
  floors = lib.sort (a: b: a.miB > b.miB) (map (i: { inherit (i) id; kind = i.config.vm.guestKind; miB = floorOf i.config.vm; })
    (lib.filter (i: i.config.vm.power == "on") (lib.attrValues lab.instances)));
  sumOf = kind: lib.foldl' (acc: f: acc + f.miB) 0 (lib.filter (f: f.kind == kind) floors);
  totalMiB = sumOf "vm" + sumOf "lxc" + node.arcMaxMiB + node.reserveMiB;
  budgetLaws = lib.optional (totalMiB > node.memoryMiB)
    ("host memory: vm floors ${toString (sumOf "vm")} + lxc limits ${toString (sumOf "lxc")} + arc ${toString node.arcMaxMiB}"
      + " + reserve ${toString node.reserveMiB} = ${toString totalMiB} MiB, over the node's ${toString node.memoryMiB} MiB"
      + " by ${toString (totalMiB - node.memoryMiB)}; largest: "
      + lib.concatMapStringsSep ", " (f: "${f.id} ${toString f.miB}") (lib.take largestShown floors));
in
needsLaws ++ budgetLaws
