{ config, pkgs, lib, catalog, site, ... }:
let
  ntfy = import ../../modules/ntfy.nix;
  inherit (ntfy) topics;
  route = catalog.external.ntfy;

  # every account ntfy has (ntfy-users-prune removes the rest); password: its sops secret, null for token-only
  users = {
    luca = { password = "ntfy-admin-password"; role = "admin"; access = { }; };
    grafana = { password = "ntfy-grafana-password"; role = "user";
                access = { ${topics.alerts} = "write-only"; ${topics.heartbeat} = "write-only"; }; };
    hermes = { password = "ntfy-hermes-password"; role = "user"; access = { ${topics.hermes} = "read-write"; }; };
    desktop = { password = null; role = "user"; access = { ${topics.alerts} = "read-only"; }; };
    # the heartbeat check below; its token is made here and never leaves the host
    heartbeat = { password = null; role = "user";
                  access = { ${topics.heartbeat} = "read-only"; ${topics.alerts} = "write-only"; }; };
  };
  secretUsers = lib.filterAttrs (_: u: u.password != null) users;

  stateDir = "/var/lib/ntfy-sh";
  authUnit = "ntfy-auth";
  authDir = "/var/lib/${authUnit}";
  authEnv = "/run/${authUnit}/auth.env";
  heartbeatToken = "${authDir}/heartbeat.token";

  # one missed beat is a hiccup
  inherit (ntfy) heartbeatIntervalMin;
  heartbeatMissedMax = 3;
  heartbeatWindowMin = heartbeatIntervalMin * heartbeatMissedMax;
  local = "http://127.0.0.1:${toString route.port}";
in {
  sops.secrets = lib.mapAttrs' (_: u: lib.nameValuePair u.password { restartUnits = [ "ntfy-sh.service" ]; }) secretUsers
    // { ntfy-desktop-token.restartUnits = [ "ntfy-sh.service" ]; };

  # NTFY_AUTH_* from the sops passwords; partOf: a restart of ntfy (a changed secret) renders them first
  systemd.services.${authUnit} = {
    description = "Render ntfy's provisioned accounts";
    before = [ "ntfy-sh.service" ];
    requiredBy = [ "ntfy-sh.service" ];
    partOf = [ "ntfy-sh.service" ];
    path = [ pkgs.ntfy-sh pkgs.coreutils pkgs.gnugrep pkgs.openssl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      RuntimeDirectory = authUnit;
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = true;
      StateDirectory = authUnit;
      StateDirectoryMode = "0700";
    };
    script = ''
      set -euo pipefail
      # `ntfy user hash` prompts twice on stdout, then prints the hash
      hash_of() { printf '%s\n%s\n' "$1" "$1" | ntfy user hash | grep -o '\$2[aby]\$[^ ]*'; }
      # ntfy tokens are tk_ and 29 of [a-z0-9]: 15 random bytes in hex, one digit dropped
      if [ ! -s ${heartbeatToken} ]; then
        random=$(openssl rand -hex 15)
        printf 'tk_%s' "''${random:0:29}" > ${heartbeatToken}
      fi
      entries=()
      ${lib.concatStrings (lib.mapAttrsToList (name: u: ''
        hash=$(hash_of "${if u.password == null then "$(openssl rand -hex 32)" else "$(cat ${config.sops.secrets.${u.password}.path})"}")
        entries+=("${name}:$hash:${u.role}")
      '') users)}
      access=(${lib.concatStringsSep " " (lib.concatLists (lib.mapAttrsToList (name: u:
        lib.mapAttrsToList (topic: perm: "${name}:${topic}:${perm}") u.access) users))})
      tokens=("desktop:$(cat ${config.sops.secrets.ntfy-desktop-token.path}):desktop" "heartbeat:$(cat ${heartbeatToken}):heartbeat")
      join() { local IFS=,; echo "$*"; }
      umask 077
      {
        echo "NTFY_AUTH_USERS='$(join "''${entries[@]}")'"
        echo "NTFY_AUTH_ACCESS='$(join "''${access[@]}")'"
        echo "NTFY_AUTH_TOKENS='$(join "''${tokens[@]}")'"
      } > ${authEnv}.tmp
      mv ${authEnv}.tmp ${authEnv}
    '';
  };
  # a changed account set (this unit's script) must reach the running server
  systemd.services.ntfy-sh.restartTriggers = [ config.systemd.services.${authUnit}.script ];

  services.ntfy-sh = {
    enable = true;
    environmentFile = authEnv;
    settings = {
      base-url = "https://${route.host}.${site.domain}";
      listen-http = ":${toString route.port}";
      # only the zone's ingress reaches the port (the guard, modules/network.nix), its x-forwarded-for is the visitor's
      behind-proxy = true;
      auth-file = "${stateDir}/user.db";
      auth-default-access = "deny-all";
      cache-file = "${stateDir}/cache.db";
      attachment-cache-dir = "${stateDir}/attachments";
      # unauthenticated floods must not fill disk or conntrack
      visitor-request-limit-burst = 60;
      visitor-request-limit-replenish = "5s";
      visitor-subscription-limit = 30;
      visitor-attachment-total-size-limit = "50M";
      attachment-file-size-limit = "15M";
      attachment-total-size-limit = "2G";
    };
  };

  systemd.services.ntfy-users-prune = {
    description = "Remove ntfy accounts that are not provisioned";
    after = [ "ntfy-sh.service" ];
    requires = [ "ntfy-sh.service" ];
    partOf = [ "ntfy-sh.service" ];
    wantedBy = [ "ntfy-sh.service" ];
    path = [ pkgs.ntfy-sh pkgs.gawk ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -euo pipefail
      # "user <name> (role: ..., tier: ...[, server config])"; * is the anonymous user
      for name in $(ntfy user list 2>&1 | awk '$1 == "user" && $2 != "*" && !/server config\)$/ { print $2 }'); do
        ntfy user remove "$name"
        echo "removed account $name, it is not in 203-external-ntfy/main.nix"
      done
    '';
  };

  # the alerting's dead man's switch: with vm-105 silent no other alert reaches the owner, so say it once per outage
  systemd.services.heartbeat-check = {
    description = "Alert when vm-105's alerting heartbeat stops";
    after = [ "ntfy-sh.service" ];
    path = [ pkgs.curl pkgs.gnugrep pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "heartbeat-check"; };
    script = ''
      set -euo pipefail
      auth() { printf 'Authorization: Bearer %s\n' "$(cat ${heartbeatToken})"; }
      alerted=/var/lib/heartbeat-check/alerted
      if auth | curl -sSf -H @- "${local}/${topics.heartbeat}/json?poll=1&since=${toString heartbeatWindowMin}m" \
        | grep -q '"event":"message"'; then
        rm -f "$alerted"; exit 0
      fi
      [ -e "$alerted" ] && exit 0
      auth | curl -sSf -H @- -H "Title: FIRING: Monitoring silent" -H "Tags: rotating_light" -o /dev/null \
        -d "No heartbeat from vm-105 for ${toString heartbeatWindowMin} minutes: Grafana alerting, Prometheus or the guest is down. No other alert can reach you until it is back." \
        "${local}/${topics.alerts}"
      touch "$alerted"
    '';
  };
  systemd.timers.heartbeat-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "${toString heartbeatWindowMin}m"; OnUnitActiveSec = "${toString heartbeatIntervalMin}m"; };
  };
}
