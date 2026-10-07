# a guest's declared needs (instance.nix `vm.needs`) are what its configuration uses, so the kind the rule derives
# from them (modules/instance-schema.nix) is the kind it must be: its own container runtime, nfs (client or server)
{ lib, configs, ... }:
let
  lab = import ../../modules/lab { inherit lib; };
  usesOf = c: lib.optional (c.virtualisation.podman.enable || c.virtualisation.docker.enable
      || c.virtualisation.oci-containers.containers != { } || (c.homelab.rootlessDocker or { }) != { }) "containers"
    ++ lib.optional (c.homelab.nasShares != [ ] || c.services.nfs.server.enable) "nfs";
in
lib.concatLists (lib.mapAttrsToList (name: host:
  let
    declared = lib.sort lib.lessThan lab.instances.${host.id}.config.vm.needs;
    used = usesOf configs.${name};
  in
  lib.optional (host.id != "300" && declared != used)
    "${name}: vm.needs is [ ${toString declared} ], its configuration uses [ ${toString used} ]"
) lab.hosts)
