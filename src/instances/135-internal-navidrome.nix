{ pkgs, nasMount, nasMedia, ... }: {
  networking.hostName = "vm-135";

  fileSystems = nasMount "/var/lib/navidrome" "navidrome"
    // nasMedia "/srv/music" "music"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # Lidarr: music manager. Downloads into /data/media/music, which Navidrome
  # serves. Wired to qBittorrent/Prowlarr by vm-132.
  homelab.servarr.lidarr = {
    image = "lscr.io/linuxserver/lidarr:3.1.0.4875-ls41";
    port = 8686;
    hostPort = 8686;
  };

  virtualisation.oci-containers.containers.navidrome = {
    image = "deluan/navidrome:0.64.0";
    ports = [ "80:4533" ];
    volumes = [
      "/var/lib/navidrome:/data"
      "/srv/music:/music:ro"
    ];
    environment = {
      ND_SCANSCHEDULE = "1h";
      ND_LOGLEVEL = "info";
      ND_BASEURL = "";
      ND_REVERSEPROXYUSERHEADER = "Remote-User";
      ND_REVERSEPROXYWHITELIST = "10.100.0.100/32";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/navidrome 0750 1000 1000 -"
  ];

  # admin with a generated password, and its Subsonic credentials for the Homepage widget
  systemd.services.navidrome-homepage-token = {
    description = "Initialise Navidrome admin and export Subsonic credentials for Homepage";
    after = [ "podman-navidrome.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      N=http://127.0.0.1:80
      T=/var/lib/homepage-tokens
      for i in $(seq 1 90); do
        curl -sf $N/ping >/dev/null 2>&1 && break
        sleep 2
      done

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
      # installs from before generated passwords still have admin/admin.
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
}
