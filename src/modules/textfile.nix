# the node exporter's textfile collector (modules/base): a service publishes a metric by writing <name>.prom.tmp
# into this dir and renaming it to <name>.prom, so the exporter never reads half a file
{ lib, ... }: {
  options.homelab.textfileDir = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "/var/lib/node-exporter-textfile";
    description = "Where services drop their .prom files for the node exporter.";
  };
}
