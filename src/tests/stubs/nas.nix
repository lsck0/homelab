# NAS stand-in for test vms without a nas: the mount helpers of modules/nas.nix, mounting nothing
#
# Only for tests that do not import modules/base (through stubs.nix); base.nix brings the real nas.nix, and a
# lab test that wants the real mounts serves them from a test nas (lib/lab.nix `nas`, lib/nas-mounts.nix).
{ lib, ... }: {
  options.homelab.nasMounts = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Stand-in for modules/nas.nix's option; the helpers below leave it empty.";
  };

  config._module.args = {
    nasMount = _: _: { };
    nasMountRo = _: _: { };
    nasPath = _: _: { };
    nasMedia = _: _: { };
  };
}
