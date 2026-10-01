# test stand-ins for lab secrets and templates
{ lib, config, ... }:
let
  # numeric where parsed as a number
  dummy = name: if lib.hasSuffix "chat-id" name then "12345" else "test-${name}";
in
{
  imports = [
    ../modules/network.nix
    ../modules/db-backup.nix
    ../modules/local-state.nix
  ];

  options.sops = {
    secrets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          key = lib.mkOption { type = lib.types.str; default = name; };
          path = lib.mkOption { type = lib.types.str; default = "/run/secrets/${name}"; };
          owner = lib.mkOption { type = lib.types.str; default = "root"; };
          group = lib.mkOption { type = lib.types.str; default = "root"; };
          mode = lib.mkOption { type = lib.types.str; default = "0400"; };
        };
      }));
    };
    templates = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          content = lib.mkOption { type = lib.types.str; default = ""; };
          path = lib.mkOption { type = lib.types.str; default = "/run/secrets/rendered/${name}"; };
          owner = lib.mkOption { type = lib.types.str; default = "root"; };
          mode = lib.mkOption { type = lib.types.str; default = "0400"; };
        };
      }));
    };
    placeholder = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
  };

  # declared by platform-vm.nix, which a test vm cannot import (grub, disk layout)
  options.homelab.dropCaches = lib.mkOption { type = lib.types.bool; default = true; };

  config = {
    sops.placeholder = lib.mapAttrs (name: _: dummy name) config.sops.secrets;

    # world-readable, dummy values
    system.activationScripts.sopsStub = lib.stringAfter [ "users" ] (''
      mkdir -p /run/secrets/rendered
    '' + lib.concatStrings (lib.mapAttrsToList (_: s: ''
      printf '%s' ${lib.escapeShellArg (dummy s.key)} > ${s.path}; chmod 0444 ${s.path}
    '') config.sops.secrets) + lib.concatStrings (lib.mapAttrsToList (_: t: ''
      printf '%s' ${lib.escapeShellArg t.content} > ${t.path}; chmod 0444 ${t.path}
    '') config.sops.templates));

    _module.args = {
      nasMount = _: _: { };
      nasPath = _: _: { };
      nasMedia = _: _: { };
      # network.nix reads the inventory
      inventory = lib.mkDefault { };
      # static host facts, the same file the flake hands every host
      site = lib.importJSON ../site.json;
    };
  };
}
