# a container starts from the image it has: a registry outage never stops a start once the pinned image is present
{ lib, configs, ... }:
let
  offline = [ "missing" "never" ];
in
lib.concatLists (lib.mapAttrsToList (name: config:
  lib.mapAttrsToList (container: c:
    "${name}: oci container ${container} pulls '${c.pull}' at every start; pull = one of ${toString offline}"
  ) (lib.filterAttrs (_: c: !(lib.elem c.pull offline)) config.virtualisation.oci-containers.containers)
) configs)
