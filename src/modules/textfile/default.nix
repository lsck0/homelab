# the node exporter's textfile collector (modules/base): a service writes <name>.prom.tmp into textfileDir and renames
# it to <name>.prom, so the exporter never reads half a file
#
# activation removes the files of names the previous generation declared and this one no longer does (lib/prune.nu);
# a file no generation declared is left alone, so a writer that forgot to declare loses nothing
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab;
  prune = pkgs.writers.writeNu "textfile-prune" ./lib/prune.nu;
  # names written before hosts recorded their files, taken as a host's first record; delete once every host has
  # activated a generation with this module
  legacyTextfiles = [ "app_builder" ];
in {
  options.homelab = {
    textfileDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/node-exporter-textfile";
      description = "Where services drop their .prom files for the node exporter.";
    };
    textfiles = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9_-]+[*]?");
      default = [ ];
      description = "The files this host's units write to textfileDir, without .prom; a trailing * stands for a runtime part (an app, a database).";
    };
  };

  config.system.activationScripts.textfile-prune =
    "${prune} ${cfg.textfileDir} ${lib.escapeShellArg (toString legacyTextfiles)} ${lib.escapeShellArgs cfg.textfiles}";
}
