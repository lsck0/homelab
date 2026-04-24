{ config, lib, ... }:
let
  hostname = config.networking.hostName;
  # Parse "vm-123" → 123, or null if not matching
  match = builtins.match "vm-([0-9]+)" hostname;
  vmId = if match != null then lib.toInt (builtins.head match) else null;
  type =
    if vmId != null && vmId >= 100 && vmId < 200 then "internal"
    else if vmId != null && vmId >= 200 && vmId < 300 then "external"
    else null;
  subnet =
    if type == "internal" then "10.100.0"
    else if type == "external" then "10.200.0"
    else null;
  gateway =
    if type == "internal" then "10.100.0.1"
    else if type == "external" then "10.200.0.1"
    else null;
in {
  config = lib.mkIf (subnet != null) {
    networking.useDHCP = lib.mkDefault false;
    networking.interfaces.eth0.ipv4.addresses = [{
      address = "${subnet}.${toString vmId}";
      prefixLength = 24;
    }];
    networking.defaultGateway = { address = gateway; interface = "eth0"; };
    networking.nameservers = [ gateway ];
  };
}
