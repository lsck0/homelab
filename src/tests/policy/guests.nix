# the guests against what they declare and what the node holds
#
# - a guest's declared needs (instance.nix `vm.needs`) are the kind its configuration is: containers, nfs
# - host memory budget: every powered guest's floor (a vm's balloon floor, its whole memory when unballooned, an
#   lxc's limit), each vm's qemu overhead and the node's reserve fit the node. Past it the balloon squeezes guests
#   below their floors and the node swaps; onDemand guests count, since all may wake at once
# - a service's MemoryMax fits its guest's floor less the guest's base: above it the guest's global oom fires before
#   the cap, and kills the largest process (syncthing, nfsd's clients) instead of the capped unit
# - a guest mounts exactly the shares its instance.nix declares: vm-104 exports those, so a mount it does not
#   export hangs and an export nothing mounts is open for nothing
{ lib, configs, lab, ... }:
let
  node = {
    # MemTotal: 32 GiB less the firmware's share
    memoryMiB = 32022;
    # the zfs arc is capped at 3202 MiB, but the node has no zfs pool (its storage is lvm-thin), so the arc holds nothing
    arcMaxMiB = 0;
    # what the node itself cannot give back, measured on pve 9.0: 1730 MiB of daemons (pss) and 800 MiB of unreclaimable
    # kernel memory. page cache is reclaimable, and autoballoon's 80% line squeezes guests to their floors, not below
    reserveMiB = 2560;
    # a qemu process beside its guest's memory: 100 to 300 MiB measured per vm
    qemuOverheadMiB = 150;
  };
  # an idle guest's kernel, sshd, journald and exporters
  guestBaseMiB = 512;
  # where shrinking pays
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

  sortedShares = shares: lib.sort (a: b: a.path < b.path) (map (s: { inherit (s) path readOnly mode localState; }) shares);
  shareLaws = lib.concatLists (lib.mapAttrsToList (name: host: let
      declared = sortedShares lab.shares.${host.id};
      mounted = sortedShares configs.${name}.homelab.nasShares;
    in
    lib.optional (host.id != "300" && declared != mounted)
      ("${name} mounts ${builtins.toJSON (lib.subtractLists declared mounted)} it does not declare and declares "
        + "${builtins.toJSON (lib.subtractLists mounted declared)} it does not mount: instance.nix `shares`")
  ) lab.hosts);

  floorOf = vm: if vm.guestKind == "lxc" || vm.balloonMiB == 0 then vm.memoryMiB else vm.balloonMiB;
  floors = lib.sort (a: b: a.miB > b.miB) (map (i: { inherit (i) id; kind = i.config.vm.guestKind; miB = floorOf i.config.vm; })
    (lib.filter (i: i.config.vm.power == "on") (lib.attrValues lab.instances)));
  sumOf = kind: lib.foldl' (acc: f: acc + f.miB) 0 (lib.filter (f: f.kind == kind) floors);
  overheadMiB = node.qemuOverheadMiB * lib.length (lib.filter (f: f.kind == "vm") floors);
  totalMiB = sumOf "vm" + sumOf "lxc" + overheadMiB + node.arcMaxMiB + node.reserveMiB;
  budgetLaws = lib.optional (totalMiB > node.memoryMiB)
    ("host memory: vm floors ${toString (sumOf "vm")} + lxc limits ${toString (sumOf "lxc")} + qemu ${toString overheadMiB}"
      + " + arc ${toString node.arcMaxMiB} + reserve ${toString node.reserveMiB} = ${toString totalMiB} MiB, over the"
      + " node's ${toString node.memoryMiB} MiB by ${toString (totalMiB - node.memoryMiB)}; largest: "
      + lib.concatMapStringsSep ", " (f: "${f.id} ${toString f.miB}") (lib.take largestShown floors));

  # systemd's MemoryMax: bytes or a K/M/G/T suffix (base 1024); infinity and a share of the guest are no fixed cap
  unitBytes = { "" = 1; K = 1024; M = 1024 * 1024; G = 1024 * 1024 * 1024; T = 1024 * 1024 * 1024 * 1024; };
  miBOf = value: let m = builtins.match "([0-9]+)([KMGT]?)" (toString value); in
    if m == null then null else lib.toInt (lib.elemAt m 0) * unitBytes.${lib.elemAt m 1} / unitBytes.M;
  capLaws = lib.concatLists (lib.mapAttrsToList (name: host: let
      floorMiB = floorOf lab.instances.${host.id}.config.vm;
      caps = lib.filterAttrs (_: miB: miB != null)
        (lib.mapAttrs (_: s: miBOf (s.serviceConfig.MemoryMax or "")) configs.${name}.systemd.services);
    in
    lib.mapAttrsToList (unit: miB: "${name}: ${unit} MemoryMax ${toString miB} MiB leaves less than ${toString guestBaseMiB}"
        + " MiB of the guest's ${toString floorMiB} MiB floor")
      (lib.filterAttrs (_: miB: miB > floorMiB - guestBaseMiB) caps)
  ) (lib.filterAttrs (_: host: lab.instances ? ${host.id}) lab.hosts));
in
needsLaws ++ shareLaws ++ budgetLaws ++ capLaws
