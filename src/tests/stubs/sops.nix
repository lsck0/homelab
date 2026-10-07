# sops-nix stand-in for test vms: the option surface the lab sets, secrets and templates written at activation
#
# A test node imports this in place of sops-nix (lib/lab.nix does, on top of the real modules/base). Every
# secret holds `test-<name>` unless the test gives it a real-format value, which services that parse their secret
# (wireguard, ssh, oidc) need:
#
#   testing.secretValues.wireguard-private-key = "<base64>";               # a string is the value itself
#   testing.secretValues.app-deploy-key = secretValues.app-deploy-key;     # a derivation's output file is the value
#
# Templates work as in sops-nix: `config.sops.placeholder.<name>` is a token that activation replaces with the
# secret's value, so a placeholder that leaks into a unit script stays a token here, as it would in production.
# Files are world-readable 0444 owned by root unless `testing.honorSecretPermissions` installs them with their
# declared owner, group and mode, as sops-nix does; a test about who may read a secret sets it.
{ config, lib, pkgs, ... }:
let
  cfg = config.sops;
  honor = config.testing.honorSecretPermissions;

  # numeric where parsed as a number
  dummy = name: if lib.hasSuffix "chat-id" name then "12345" else "test-${name}";
  valueOf = name: config.testing.secretValues.${name} or (dummy name);
  # sops-nix's shape, so a leaked placeholder is recognisable in any config dump
  placeholderOf = name: "<SOPS:${builtins.hashString "sha256" name}:PLACEHOLDER>";

  # owner, group and mode as declared, or the stub's world-readable default
  installFlags = f: if honor
    then "-m ${f.mode} -o ${f.owner} -g ${f.group}"
    else "-m 0444 -o root -g root";

  secretInstall = s: let value = valueOf s.key; path = lib.escapeShellArg s.path; in if builtins.isString value
    then ''printf '%s' ${lib.escapeShellArg value} | install -D ${installFlags s} /dev/stdin ${path}''
    else "install -D ${installFlags s} ${value} ${path}";

  # every placeholder in the content becomes the file content of its secret, trailing newlines included
  templateInstall = name: t: ''
    content=$(cat ${pkgs.writeText "sops-template-${name}" t.content}; printf x); content=''${content%x}
    ${lib.concatStrings (lib.mapAttrsToList (secret: s: ''
      value=$(cat ${lib.escapeShellArg s.path}; printf x); value=''${value%x}
      content=''${content//${lib.escapeShellArg (placeholderOf secret)}/"$value"}
    '') (lib.filterAttrs (secret: _: lib.hasInfix (placeholderOf secret) t.content) cfg.secrets))}
    printf '%s' "$content" | install -D ${installFlags t} /dev/stdin ${lib.escapeShellArg t.path}
  '';

  # sops-nix's defaults: root, and the owner's primary group
  fileOptions = file: {
    owner = lib.mkOption { type = lib.types.str; default = "root"; };
    group = lib.mkOption { type = lib.types.str; default = config.users.users.${file.owner}.group or "root"; };
    mode = lib.mkOption { type = lib.types.str; default = "0400"; };
    restartUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    reloadUnits = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
  };
in
{
  options.sops = {
    secrets = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = fileOptions config // {
          key = lib.mkOption { type = lib.types.str; default = name; };
          path = lib.mkOption { type = lib.types.str; default = "/run/secrets/${name}"; };
          # set by modules/base; inert here, the stub reads no sops file
          sopsFile = lib.mkOption { type = lib.types.path; };
        };
      }));
    };
    templates = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, config, ... }: {
        options = fileOptions config // {
          content = lib.mkOption { type = lib.types.str; default = ""; };
          path = lib.mkOption { type = lib.types.str; default = "/run/secrets/rendered/${name}"; };
        };
      }));
    };
    placeholder = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
    age.keyFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    age.sshKeyPaths = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    gnupg.sshKeyPaths = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
  };

  options.testing = {
    secretValues = lib.mkOption {
      type = lib.types.attrsOf (lib.types.oneOf [ lib.types.str lib.types.package ]);
      default = { };
      description = "Secret values by sops key: a string is the value, a derivation's output file holds it.";
    };
    honorSecretPermissions = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install secrets and templates with their declared owner, group and mode instead of 0444 root.";
    };
  };

  config = {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = lib.any (s: s.key == name) (lib.attrValues cfg.secrets);
      message = "testing.secretValues.${name}: no sops secret on ${config.networking.hostName} reads it";
    }) config.testing.secretValues;

    sops.placeholder = lib.mapAttrs (name: _: placeholderOf name) cfg.secrets;

    # after users and groups: an honoured owner must exist
    system.activationScripts.sopsStub = lib.stringAfter [ "users" "groups" ] ''
      install -d -m 0751 /run/secrets /run/secrets/rendered
      ${lib.concatStrings (lib.mapAttrsToList (_: s: secretInstall s + "\n") cfg.secrets)}
      ${lib.concatStrings (lib.mapAttrsToList templateInstall cfg.templates)}
    '';
  };
}
