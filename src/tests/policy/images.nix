# a container starts from the image it has: a registry outage never stops a start once the pinned image is present,
# and a tag moved upstream (a retag, a compromised account) never lands on a recreated guest: every image names its
# digest, the tag beside it for the reader
{ lib, configs, ... }:
let
  offline = [
    "missing"
    "never"
  ];
  pinned = image: builtins.match ".+@sha256:[0-9a-f]{64}" image != null;
in
lib.concatLists (
  lib.mapAttrsToList (
    name: config:
    lib.concatLists (
      lib.mapAttrsToList (
        container: c:
        lib.optional (
          !(lib.elem c.pull offline)
        ) "${name}: oci container ${container} pulls '${c.pull}' at every start; pull = one of ${toString offline}"
        ++ lib.optional (!(pinned c.image)) "${name}: oci container ${container} names ${c.image} by tag alone, no digest"
      ) config.virtualisation.oci-containers.containers
    )
  ) configs
)
