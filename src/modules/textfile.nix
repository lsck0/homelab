# the node exporter's textfile collector (modules/base): a service publishes a metric by writing <name>.prom.tmp into
# textfileDir and renaming it to <name>.prom, so the exporter never reads half a file. Every writer names its files in
# homelab.textfiles; activation removes any other, so a writer that moved hosts or went away leaves no stale metric.
{ config, lib, ... }:
let
  cfg = config.homelab;
in {
  options.homelab = {
    textfileDir = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "/var/lib/node-exporter-textfile";
      description = "Where services drop their .prom files for the node exporter.";
    };
    textfiles = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9_]+[*]?");
      default = [ ];
      description = "The files this host's units write to textfileDir, without .prom; a trailing * stands for a runtime part (an app, a database).";
    };
  };

  config.system.activationScripts.textfile-prune = ''
    for file in ${cfg.textfileDir}/*.prom ${cfg.textfileDir}/*.prom.tmp; do
      [ -e "$file" ] || continue
      name=''${file##*/}
      name=''${name%.tmp}
      ${lib.optionalString (cfg.textfiles != [ ]) ''
        case "''${name%.prom}" in ${lib.concatStringsSep "|" cfg.textfiles}) continue ;; esac
      ''}
      rm -f "$file"
      echo "textfile: removed $file, no unit of this host writes it"
    done
  '';
}
