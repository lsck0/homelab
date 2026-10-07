# push notifications (alert delivery)
{ telemetry, ... }:
let
  port = 80;
in {
  vm = {
    bootPhase = "public";
    kind.lxc = "pending migration, see the restructure report";
  };

  services = {
    ntfy = {
      inherit port;
      homepage = { group = "Public"; icon = "ntfy"; name = "ntfy"; };
      off = {
        sso = "public push notifications; ntfy checks its own accounts";
        anubis = "the phone app and vm-105 publish natively";
        waf = "publishers and subscribers are api clients the rules misread";
        bodyLimit = "attachments";
      };
    };
  };

  grants = [{
    from = [ telemetry.collectorVmid ];
    tcp = [ port ];
    why = "grafana delivers alerts and the heartbeat straight to ntfy: an edge fault must not swallow them";
  }];

  secrets = {
    ntfy-admin-password = "hex:24";
    ntfy-desktop-token = "ntfy-token"; # mirrored to the dotfiles' ntfy client
    healthchecks-ping-uuid = "manual"; # the off-site check's ping url, from the owner's healthchecks.io account
  };
}
