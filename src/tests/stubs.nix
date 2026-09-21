# Test stand-ins for things the VMs get from the lab: sops secrets and templates
# (dummy values rendered into /run/secrets at activation) and NAS mounts (plain
# local directories).
#
# The homelab.* options an instance file may set are pulled in from their real
# modules rather than re-declared here, so a test cannot drift from the option
# it is standing in for. Both are inert in a test node: network.nix only
# configures interfaces for a `vm-<id>` hostname, and db-backup.nix only creates
# units when a database is declared.
{ lib, config, ... }:
let
  # numeric where the consumer parses a number (the Telegram chat id).
  dummy = name: if lib.hasSuffix "chat-id" name then "12345" else "test-${name}";
in
{
  imports = [
    ../modules/network.nix
    ../modules/db-backup.nix
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

  config = {
    sops.placeholder = lib.mapAttrs (name: _: dummy name) config.sops.secrets;

    # readable by everyone: tests only, dummy values.
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
      # network.nix (imported above for the homelab.ingressOnly option) reads the
      # inventory. mkDefault so a test that wants real entries can still set it.
      inventory = lib.mkDefault { };
    };
  };
}
