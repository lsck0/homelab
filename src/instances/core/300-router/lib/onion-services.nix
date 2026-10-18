# the router's onion services: every route whose `onion` is on, published by its tor and served by the edge
#
# Rejected: a key tor generates on first start: it lives on the router's disk alone (losing it loses the address) and
# is unknown when the edge's rules are evaluated. The key is the secret <route>-onion-key instead.
{ config, lib, pkgs, inventory, site, catalog, ... }:
let
  net = import ../../../../modules/net.nix { inherit lib inventory site; };
  service = import ../../../../modules/service.nix { inherit lib; };
  torPorts = import ../../../../modules/tor-ports.nix;

  onionRoutes = lib.filterAttrs (_: r: r.onion) catalog.external;
  keyDir = "/run/tor-onion-keys";
  # the onion service is the encryption
  virtualPort = net.ports.http;
  # --stdin: a nu script's main sees its stdin only with it
  onionKey = "${lib.getExe pkgs.nushell} --no-config-file --stdin ${../../../../scripts/lib/onion.nu} secret-key";
in {
  services.tor.relay.onionServices = lib.mapAttrs (name: _: {
    version = 3;
    map = [ { port = virtualPort; target = { addr = net.ipOf net.zones.external.ingress; port = torPorts.onionIngress; }; } ];
    secretKey = "${keyDir}/${name}";
  }) onionRoutes;

  sops.secrets = lib.mapAttrs' (name: _: lib.nameValuePair (service.onionKeyOf name) { restartUnits = [ "tor.service" ]; }) onionRoutes;

  systemd.services.tor-onion-keys = lib.mkIf (onionRoutes != { }) {
    description = "Turn the onion routes' seeds into tor's key files";
    before = [ "tor.service" ];
    requiredBy = [ "tor.service" ];
    partOf = [ "tor.service" ];
    path = [ pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = baseNameOf keyDir;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
    };
    script = lib.concatMapStrings (name: ''
      ${onionKey} < ${config.sops.secrets.${service.onionKeyOf name}.path} > ${keyDir}/${name}
    '') (lib.attrNames onionRoutes);
  };
}
