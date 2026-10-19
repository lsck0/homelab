# a per-connection unit (Accept=yes) is collected when it ends: one killed at RuntimeMaxSec or failing on a bad
# client would otherwise stay failed, and alert, until the next switch resets it
{ lib, configs, ... }:
let
  accepting = lib.filterAttrs (
    _: s:
    lib.elem (s.socketConfig.Accept or false) [
      true
      "yes"
    ]
  );
in
lib.concatLists (
  lib.mapAttrsToList (
    name: config:
    lib.concatLists (
      lib.mapAttrsToList (
        socket: _:
        let
          template = "${socket}@";
        in
        lib.optional (
          (config.systemd.services.${template}.unitConfig.CollectMode or null) != "inactive-or-failed"
        ) "${name}: ${template}.service, the per-connection unit of ${socket}.socket, lacks CollectMode = inactive-or-failed"
      ) (accepting config.systemd.sockets)
    )
  ) configs
)
