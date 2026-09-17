{ pkgs, nasMount, nasPath, ... }: {
  networking.hostName = "vm-134";

  fileSystems = nasMount "/var/lib/audiobookshelf" "audiobookshelf"
    // nasPath "/srv/audiobooks" "media/audiobooks"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # Bookshelf (maintained Readarr fork, Hardcover metadata): ebook manager.
  # downloads into /data/media/books, which Kavita serves. Wired by vm-132.
  homelab.servarr.bookshelf = {
    image = "ghcr.io/pennydreadful/bookshelf:hardcover";
    port = 8787;
    hostPort = 8787;
  };

  virtualisation.oci-containers.containers.audiobookshelf = {
    image = "ghcr.io/advplyr/audiobookshelf:latest";
    ports = [ "80:80" ];
    volumes = [
      "/srv/audiobooks:/audiobooks"
      "/var/lib/audiobookshelf/config:/config"
      "/var/lib/audiobookshelf/metadata:/metadata"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/audiobookshelf/config 0750 1000 1000 -"
    "d /var/lib/audiobookshelf/metadata 0750 1000 1000 -"
  ];

  # admin with a generated password, and its API token for the Homepage widget
  systemd.services.audiobookshelf-homepage-token = {
    description = "Initialise Audiobookshelf admin and export its API token for Homepage";
    after = [ "podman-audiobookshelf.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      A=http://127.0.0.1:80
      T=/var/lib/homepage-tokens
      for i in $(seq 1 90); do
        curl -sf $A/healthcheck >/dev/null 2>&1 && break
        sleep 2
      done

      [ -s $T/audiobookshelf-pass.token ] || openssl rand -hex 16 | tr -d '\n' > $T/audiobookshelf-pass.token
      PASS=$(cat $T/audiobookshelf-pass.token)
      json() { jq -cn --arg p "$1" "$2"; }
      login() { # password
        curl -sf -X POST $A/login -H "Content-Type: application/json" \
          -d "$(json "$1" '{username:"admin", password:$p}')" | jq -r '.user.token // empty'
      }

      if curl -sf $A/status | jq -e '.isInit == false' >/dev/null; then
        curl -sf -X POST $A/init -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{newRoot:{username:"admin", password:$p}}')"
      fi

      TOKEN=$(login "$PASS")
      # installs from before generated passwords still have admin/admin.
      if [ -z "$TOKEN" ] && OLD=$(login admin) && [ -n "$OLD" ]; then
        curl -sf -X PATCH $A/api/me/password -H "Authorization: Bearer $OLD" -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{password:"admin", newPassword:$p}')"
        TOKEN=$(login "$PASS")
        echo "admin moved off the default password"
      fi
      [ -n "$TOKEN" ] || { echo "Audiobookshelf admin login failed"; exit 1; }
      echo -n "$TOKEN" > $T/audiobookshelf-key.token
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
