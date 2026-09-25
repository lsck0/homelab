{ config, pkgs, lib, retry, ... }:
let
  # one ntfy account per publisher, each restricted to the topics it needs. ntfy has
  users = {
    luca = { secret = "ntfy-admin-password"; role = "admin"; access = { }; };
    grafana = { secret = "ntfy-grafana-password"; role = "user"; access = { "homelab-alerts" = "write-only"; }; };
    hermes = { secret = "ntfy-hermes-password"; role = "user"; access = { "homelab-hermes" = "read-write"; }; };
  };
in {
  networking.hostName = "vm-203";

  sops.secrets = lib.mapAttrs' (_: u: lib.nameValuePair u.secret { }) users;

  # ntfy push notifications.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.lsck0.dev";
      listen-http = ":80";
      behind-proxy = true;
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";
      cache-file = "/var/lib/ntfy-sh/cache.db";
      attachment-cache-dir = "/var/lib/ntfy-sh/attachments";
      # an unauthenticated flood must not be able to fill the disk or the connection table
      visitor-request-limit-burst = 60;
      visitor-request-limit-replenish = "5s";
      visitor-subscription-limit = 30;
      visitor-attachment-total-size-limit = "50M";
      attachment-file-size-limit = "15M";
      attachment-total-size-limit = "2G";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/ntfy-sh 0750 ntfy-sh ntfy-sh -"
  ];

  # seed the accounts and their per-topic ACLs.
  systemd.services.ntfy-users = {
    description = "Seed ntfy users and per-topic access";
    after = [ "ntfy-sh.service" ];
    requires = [ "ntfy-sh.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.ntfy-sh pkgs.curl pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 15;
    };
    script = ''
      set -euo pipefail
      ${retry} 60 2 curl -sf -o /dev/null http://127.0.0.1:80/v1/health

      ${lib.concatStrings (lib.mapAttrsToList (name: u: ''
        NTFY_PASSWORD=$(cat ${config.sops.secrets.${u.secret}.path})
        export NTFY_PASSWORD
        if ntfy user list 2>/dev/null | grep -q '^user ${name} '; then
          ntfy user change-pass ${name}
          ntfy user change-role ${name} ${u.role}
        else
          ntfy user add --role=${u.role} ${name}
        fi
        ${lib.concatStrings (lib.mapAttrsToList (topic: perm: ''
          ntfy access ${name} ${topic} ${perm}
        '') u.access)}
      '') users)}
      unset NTFY_PASSWORD
      echo "ntfy users seeded: ${lib.concatStringsSep " " (lib.attrNames users)}"
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
