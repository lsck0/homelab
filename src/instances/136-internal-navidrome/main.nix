{ config, lib, pkgs, inventory, site, catalog, nasMount, nasMedia, retry, setupUnit, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  route = catalog.internal.navidrome;
  containerPort = 4533;
  local = "http://127.0.0.1:${toString route.port}";
  stateDir = "/var/lib/navidrome";
  musicDir = "/srv/music";
  uid = "1000";
  adminUser = "admin";
  # the subsonic api level hermes speaks (navidrome skill)
  subsonicApiVersion = "1.16.1";
in {
  networking.hostName = "vm-136";

  homelab.nasMounts = nasMount stateDir "navidrome" // nasMedia musicDir "music";

  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:0.64.0";
    ports = [ "${toString route.port}:${toString containerPort}" ];
    volumes = [
      "${stateDir}:/data"
      "${musicDir}:/music:ro"
    ];
    # ~250 MiB: vm 30d peak 498 minus the idle base
    extraOptions = [ "--memory=384m" ];
    environment = {
      # daily: every scan walks the music tree and spins up the hdd
      ND_SCANSCHEDULE = "24h";
      ND_ENABLEINSIGHTSCOLLECTOR = "false";
      # browser logins come from authelia through the internal ingress, the only source trusted with the header
      ND_REVERSEPROXYUSERHEADER = "Remote-User";
      ND_REVERSEPROXYWHITELIST = net.hostSource net.zones.internal.ingress;
    };
  };

  systemd.tmpfiles.rules = [ "d ${stateDir} 0750 ${uid} ${uid} -" ];

  # the admin account on a fresh library, and its subsonic credentials for hermes (navidrome skill)
  sops.secrets.navidrome-pass = { };

  systemd.services.navidrome-setup = setupUnit {
    description = "Create the Navidrome admin and export its Subsonic credentials";
    after = [ "podman-navidrome.service" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq ];
    script = ''
      ${retry} 90 2 curl -sf ${local}/ping
      # the password goes on stdin, never on argv
      credentials() { jq -cn --rawfile p ${config.sops.secrets.navidrome-pass.path} '{username: "${adminUser}", password: $p}'; }

      # first-run endpoint, refused once an admin exists
      credentials | curl -s -o /dev/null -X POST ${local}/auth/createAdmin -H "Content-Type: application/json" -d @-

      printf ${adminUser} | token_write navidrome-user
      # a token/salt pair stays valid as long as the password: rewriting it each run would hand a reader a new
      # token with the old salt in between
      if t=$(token_read navidrome-token) && s=$(token_read navidrome-salt) \
        && curl -sf "${local}/rest/ping?u=${adminUser}&t=$t&s=$s&v=${subsonicApiVersion}&c=setup&f=json" \
          | jq -e '.["subsonic-response"].status == "ok"' >/dev/null; then
        exit 0
      fi
      login=$(credentials | curl -sSf -X POST ${local}/auth/login -H "Content-Type: application/json" -d @-)
      jq -j .subsonicSalt <<<"$login" | token_write navidrome-salt
      jq -j .subsonicToken <<<"$login" | token_write navidrome-token
    '';
  };

  networking.firewall.allowedTCPPorts = [ route.port ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.navidrome.sqlite = "${stateDir}/navidrome.db";
}
