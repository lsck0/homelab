# the node exporter's textfile collector (modules/base): a service publishes a metric by writing <name>.prom.tmp into
# textfileDir and renaming it to <name>.prom, so the exporter never reads half a file.
#
# Every writer names its files in homelab.textfiles. Activation records them and removes the files of names the
# previous generation recorded and this one no longer declares (lib/prune.sh): a unit that went away or moved to
# another host leaves no stale metric behind. A file no generation declared is left alone, so a writer that forgot
# to declare loses nothing.
#
# legacyTextfiles: names hosts wrote before they recorded their files (generation 448 and earlier). A host's first
# activation takes them as its previous record, so they go wherever no unit writes them now: the builder's file on
# vm-117, which left for vm-140 and paged "app deploy failed" from its last 0. Delete the list once every host has
# activated a generation with this module.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab;
  prune = pkgs.writeShellScript "textfile-prune" (builtins.readFile ./lib/prune.sh);
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
