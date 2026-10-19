# crowdsec merges config.yaml.local over the image's config.yaml (tests/crowdsec-local-config.nix)
{
  pkgs,
  lib,
  metricsPort,
}:
let
  crowdsecHub = import ./crowdsec-hub.nix { inherit pkgs lib; };
in
# hub_branch: without it every start asks version.crowdsec.net, and a start without internet fails.
# log_level: podman's journald driver tags container output err, and the lapi's per-request info lines (5000 a day)
# buried every real error. use_wal: without it lapi warns that sqlite may leave it unresponsive.
# flush: the deception's 24h bans filled the image's 5000 alerts within hours; max_age still bounds the database
pkgs.writeText "config.yaml.local" (
  builtins.toJSON {
    cscli.hub_branch = crowdsecHub.hubBranch;
    api.server.log_level = "warning";
    db_config = {
      use_wal = true;
      flush = {
        max_items = 20000;
        max_age = "7d";
      };
    };
    # decisions, parser hits, appsec blocks and bucket overflows for vm-103
    prometheus = {
      enabled = true;
      level = "full";
      listen_addr = "0.0.0.0";
      listen_port = metricsPort;
    };
  }
)
