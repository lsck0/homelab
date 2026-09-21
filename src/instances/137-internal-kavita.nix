{ pkgs, nasMount, nasMedia, nasPath, ... }: {
  networking.hostName = "vm-137";

  fileSystems = nasMount "/var/lib/kavita" "kavita"
    // nasMedia "/srv/manga" "manga"
    // nasMedia "/srv/books" "books"
    // nasPath "/var/lib/suwayomi/downloads" "media/manga"
    // nasMount "/var/lib/suwayomi/data" "suwayomi"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  virtualisation.oci-containers.containers.kavita = {
    image = "jvmilazz0/kavita:0.9.1";
    ports = [ "80:5000" ];
    volumes = [
      "/var/lib/kavita:/kavita/config"
      "/srv/manga:/manga:ro"
      "/srv/books:/books:ro"
    ];
  };

  # suwayomi (Tachiyomi server): add manga in its UI (manga.lsck0.dev) or via
  # Hermes; new chapters of library manga are checked every 6h and downloaded
  # as CBZ straight into Kavita's manga library.
  virtualisation.oci-containers.containers.suwayomi = {
    image = "ghcr.io/suwayomi/suwayomi-server:v2.3.2243";
    ports = [ "4567:4567" ];
    volumes = [
      "/var/lib/suwayomi/data:/home/suwayomi/.local/share/Tachidesk"
      "/var/lib/suwayomi/downloads:/home/suwayomi/.local/share/Tachidesk/downloads"
    ];
    environment = {
      TZ = "Europe/Berlin";
      DOWNLOAD_AS_CBZ = "true";
      AUTO_DOWNLOAD_CHAPTERS = "true";
      UPDATE_INTERVAL = "6";
      # community extension store (sources). Install sources in the UI.
      EXTENSION_STORES = ''["https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json"]'';
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/kavita 0750 1000 1000 -"
  ];

  # first-run admin, Homepage credentials and the two libraries
  # (Manga <- Suwayomi, Books <- Bookshelf). Idempotent.
  systemd.services.kavita-setup = {
    description = "Initialise Kavita admin, libraries and Homepage credentials";
    after = [ "podman-kavita.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.curl pkgs.coreutils pkgs.jq pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 60; };
    script = ''
      K=http://127.0.0.1:80
      T=/var/lib/homepage-tokens
      [ -s $T/kavita-pass.token ] || openssl rand -hex 12 | tr -d '\n' > $T/kavita-pass.token
      PASS=$(cat $T/kavita-pass.token)
      json() { jq -cn --arg p "$1" "$2"; }
      login() { # password
        curl -sf -X POST "$K/api/Account/login" -H "Content-Type: application/json" \
          -d "$(json "$1" '{username:"admin", password:$p}')" | jq -r '.token // empty'
      }
      # first registered user becomes admin; later calls are refused. Kavita
      # answers HTTP long before login works (first-start migrations): retry.
      JWT=""
      for i in $(seq 1 60); do
        curl -s -X POST "$K/api/Account/register" -H "Content-Type: application/json" \
          -d "$(json "$PASS" '{username:"admin", password:$p, email:"admin@internal"}')" >/dev/null || true
        JWT=$(login "$PASS" || true); [ -n "$JWT" ] && break
        # installs from before generated passwords still have the old default.
        OLD=$(login 'Admin123!' || true)
        if [ -n "$OLD" ]; then
          curl -sf -X POST "$K/api/Account/reset-password" -H "Authorization: Bearer $OLD" -H "Content-Type: application/json" \
            -d "$(json "$PASS" '{userName:"admin", password:$p, oldPassword:"Admin123!"}')" >/dev/null \
            && echo "admin moved off the default password" && continue
        fi
        sleep 5
      done
      [ -n "$JWT" ] || { echo "Kavita login failed"; exit 1; }
      echo -n admin > $T/kavita-user.token

      existing=$(curl -sf "$K/api/Library/libraries" -H "Authorization: Bearer $JWT" | jq -r '.[].name')
      add() { # name type metadataProvider folder   (type: 0 manga, 2 book; provider: 2 Hardcover, 3 Mangabaka)
        echo "$existing" | grep -qx "$1" && return 0
        curl -sf -X POST "$K/api/Library/create" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
          -d "$(jq -cn --arg n "$1" --argjson t "$2" --argjson mp "$3" --arg f "$4" '{name:$n, type:$t, metadataProvider:$mp, folders:[$f],
                folderWatching:true, includeInDashboard:true, includeInSearch:true,
                manageCollections:true, manageReadingLists:true, allowScrobbling:false,
                fileGroupTypes:[1,2,3,4], excludePatterns:[]}')" \
          && echo "Kavita library $1 created"
      }
      add Manga 0 3 /manga
      add Books 2 2 /books
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 4567 ];

  # Suwayomi has no authentication at all; Kavita keeps its own login, so only
  # Suwayomi's port is restricted to the Authelia-gated ingress.
  homelab.ingressOnly.ports = [ 4567 ];
}
