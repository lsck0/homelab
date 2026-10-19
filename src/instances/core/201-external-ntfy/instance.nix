# push notifications (alert delivery)
{ lib, profiles, ... }:
let
  port = 80;
in
{
  vm = {
    bootPhase = "public";
    kind.lxc = "an existing lxc with local state; recreating it as a vm needs a data migration";
  };

  grants = [
    {
      from = [ "collector" ];
      tcp = [ port ];
      why = "grafana publishes the alerts here directly, never through the edge";
    }
  ];

  services = {
    ntfy = {
      inherit port;
      homepage = {
        group = "Public";
        icon = "ntfy";
        name = "ntfy";
      };
      # api clients: the phone app and vm-103 publish and subscribe natively, with attachments the waf rules misread
      on =
        lib.subtractLists [ "anubis" "captcha" "waf" "bodyLimit" ] profiles.hardenedExternal
        ++ profiles.listed
        ++ profiles.observed;
    };
  };

  secrets = {
    ntfy-admin-password = "hex:24";
    ntfy-desktop-token = "dotfiles:ntfy-desktop-token"; # the desktop's ntfy client reads the same file
    deadman-ping-url = "manual"; # the off-site dead man's switch's ping url (healthchecks.io or alike)
  };

  alerts.deadman_unavailable = {
    title = "Dead man's switch unavailable";
    category = "monitoring";
    # written after each beat (main.nix heartbeat-check); a beat that stopped is the heartbeat's own alert
    expr = "max_over_time(homelab_deadman_ping_ok[30m])";
    op = "lt";
    threshold = 1;
    # a gauge never written is a switch that never took a ping; the delay covers a fresh boot's first beat
    for = "30m";
    noData = "Alerting";
    summary = "The off-site dead man's switch has not taken a ping for 30 minutes";
    description = "An outage of the whole site would page no one meanwhile. An empty deadman-ping-url was never set up: create a check (healthchecks.io, period 5m, grace 15m, alerting by e-mail) and `sops` its ping url into 201-external-ntfy/secrets.sops.json. Otherwise check the provider's status; vm-201 pings it with every beat. `journalctl -u heartbeat-check` on vm-201.";
  };
}
