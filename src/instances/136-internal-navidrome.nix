{ pkgs, nasMount, nasMedia, retry, ... }: {
  networking.hostName = "vm-136";

  fileSystems = nasMount "/var/lib/navidrome" "navidrome"
    // nasMedia "/srv/music" "music"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:0.64.0";
    ports = [ "80:4533" ];
    volumes = [
      "/var/lib/navidrome:/data"
      "/srv/music:/music:ro"
    ];
    environment = {
      # daily: every scan walks the music tree and spins up the hdd
      ND_SCANSCHEDULE = "24h";
      ND_LOGLEVEL = "info";
      ND_BASEURL = "";
      ND_REVERSEPROXYUSERHEADER = "Remote-User";
      ND_REVERSEPROXYWHITELIST = "10.100.0.100/32";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/navidrome 0750 1000 1000 -"
  ];

  # admin and subsonic credentials for homepage
  systemd.services.navidrome-homepage-token = {
    description = "Initialise Navidrome admin and export Subsonic credentials for Homepage";
    after = [ "podman-navidrome.service" ];
    # an lxc mounts nfs at boot, not on access: never write under an empty mountpoint
    unitConfig.RequiresMountsFor = [ "/var/lib/homepage-tokens" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      N=http://127.0.0.1:80
      T=/var/lib/homepage-tokens
      ${retry} 90 2 curl -sf $N/ping

      [ -s $T/navidrome-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/navidrome-pass.token
      PASS=$(cat $T/navidrome-pass.token)
      json() { jq -cn --arg p "$1" "$2"; }
      login() { # password
        curl -sf -X POST $N/auth/login -H "Content-Type: application/json" -d "$(json "$1" '{username:"admin", password:$p}')"
      }

      # first-run endpoint, refused once an admin exists
      curl -sf -X POST $N/auth/createAdmin -H "Content-Type: application/json" \
        -d "$(json "$PASS" '{username:"admin", password:$p}')" >/dev/null || true

      RESP=$(login "$PASS" || true)
      # migrate old admin/admin installs
      if [ -z "$RESP" ] && OLD=$(login admin); then
        curl -sf -X PUT "$N/api/user/$(echo "$OLD" | jq -r .id)" \
          -H "x-nd-authorization: Bearer $(echo "$OLD" | jq -r .token)" -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{userName:"admin", name:"admin", isAdmin:true, password:$p, currentPassword:"admin", changePassword:true}')" >/dev/null
        RESP=$(login "$PASS" || true)
        echo "admin moved off the default password"
      fi
      [ -n "$RESP" ] || { echo "Navidrome admin login failed"; exit 1; }
      echo -n admin > $T/navidrome-user.token
      echo "$RESP" | jq -j .subsonicToken > $T/navidrome-token.token
      echo "$RESP" | jq -j .subsonicSalt > $T/navidrome-salt.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.navidrome.sqlite = "/var/lib/navidrome/navidrome.db";
}
