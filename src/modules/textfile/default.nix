# the node exporter's textfile collector (modules/base): a service publishes a metric by writing <name>.prom.tmp into
# textfileDir and renaming it to <name>.prom, so the exporter never reads half a file.
#
# Every writer names its files in homelab.textfiles. Activation records them and removes the files of names the
# previous generation recorded and this one no longer declares (lib/prune.sh): a unit that went away or moved to
# another host leaves no stale metric behind. A file no generation declared is left alone, so a writer that forgot
# to declare loses nothing.
{ config, lib, pkgs, ... }:
let
  cfg = config.homelab;
  prune = pkgs.writeShellScript "textfile-prune" (builtins.readFile ./lib/prune.sh);
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

  config.system.activationScripts.textfile-prune = "${prune} ${cfg.textfileDir} ${lib.escapeShellArgs cfg.textfiles}";
}
