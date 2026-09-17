{ config, lib, inventory, ... }:
let
  # "vm-135" -> the inventory entry for 135 (address from src/lib.tf); null for
  # hosts outside the inventory naming, like the router, which configures itself.
  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  vm = if match == null then null else inventory.${builtins.head match} or null;
in {
  config = lib.mkIf (vm != null) {
    networking.useDHCP = lib.mkDefault false;
    networking.interfaces.eth0.ipv4.addresses = [{ address = vm.ip; prefixLength = vm.prefix; }];
    networking.defaultGateway = { address = vm.gateway; interface = "eth0"; };
    networking.nameservers = [ vm.gateway ];

    # a fresh VM boots as "nixos"; switching does not rename the running kernel,
    # so logs shipped by hostname (rsyslog -> Wazuh) would say nixos until reboot.
    system.activationScripts.hostname = "echo ${config.networking.hostName} > /proc/sys/kernel/hostname";
  };
}
