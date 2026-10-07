# the guest's nixos configuration: the lab's facts arrive as module arguments (lab, catalog, inventory, site); the
# service ports of instance.nix are opened and guarded already (modules/network.nix)
{ ... }: {
  services.nginx.enable = true;
}
