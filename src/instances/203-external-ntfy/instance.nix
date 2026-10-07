# push notifications (alert delivery)
{ telemetry, ... }:
let
  port = 80;
in {
  vm = {
    bootPhase = "public";
    kind.lxc = "pending migration, see the restructure report";
  };

  grants = [
    { from = [ telemetry.collectorVmid ]; tcp = [ port ]; why = "grafana publishes the alerts here directly, never through the edge"; }
  ];

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

  secrets = {
    ntfy-admin-password = "hex:24";
    ntfy-desktop-token = "ntfy-token"; # mirrored to the dotfiles' ntfy client
    deadman-ping-url = "manual"; # the off-site dead man's switch's ping url (healthchecks.io or alike)
  };

  alerts.deadman_unavailable = {
    title = "Dead man's switch unavailable";
    category = "monitoring";
    # written after each beat (main.nix heartbeat-check); a beat that stopped is the heartbeat's own alert
    expr = "max_over_time(homelab_deadman_ping_ok[30m])";
    op = "lt"; threshold = 1;
    for = "0m";
    summary = "The off-site dead man's switch has not taken a ping for 30 minutes";
    description = "An outage of the whole site would page no one meanwhile. Check the provider's status; vm-203 pings it again with every beat and this resolves by itself. `journalctl -u heartbeat-check` on vm-203.";
  };
}
