{ config, pkgs, lib, nasMount, ... }:
let
  stateDir = "/var/lib/calendar";
  publicDir = "${stateDir}/public";
  # where PUT lands, and where a file is promoted to once it parses.
  incomingDir = "${stateDir}/incoming";
  uploadDir = "${stateDir}/uploads";

  # kraken pair codes, not the display symbols: XXBTZEUR is BTC/EUR.
  krakenPairs = "XXBTZEUR,XETHZEUR";

  # Calendars that cannot be subscribed to, only exported by hand. The work
  # Outlook tenant blocks calendar publishing, so there is no URL to poll: the
  # .ics is pushed here instead and read back as a file:// source.
  uploadNames = [ "work" ];

  # A pushed file must never be able to blank out a working calendar, so PUT
  # writes to incoming/ and this promotes it to uploads/ only once it parses as
  # a calendar. A truncated upload, an HTML error page saved as .ics, or a
  # half-finished transfer leaves the previous good copy in place.
  promote = pkgs.writers.writePython3Bin "calendar-promote" {
    libraries = [ pkgs.python3Packages.icalendar ];
    flakeIgnore = [ "E501" ];
  } ''
      import os
      import shutil
      import sys

      from icalendar import Calendar

      incoming, uploads = sys.argv[1], sys.argv[2]
      os.makedirs(uploads, exist_ok=True)
      rc = 0

      for entry in sorted(os.listdir(incoming)):
          if not entry.endswith(".ics"):
              continue
          src = os.path.join(incoming, entry)
          if os.path.getsize(src) == 0:
              print(f"{entry}: empty, ignored")
              continue
          try:
              calendar = Calendar.from_ical(open(src, "rb").read())
              events = [c for c in calendar.walk() if c.name == "VEVENT"]
          except Exception as err:  # noqa: BLE001 - a bad push must not break the good copy
              print(f"{entry}: not a calendar ({err}), keeping the previous copy")
              rc = 1
              os.replace(src, src + ".rejected")
              continue
          shutil.move(src, os.path.join(uploads, entry))
          print(f"{entry}: accepted, {len(events)} events")

      sys.exit(rc)
  '';

  calendarSync = pkgs.writers.writePython3Bin "calendar-sync" {
    libraries = with pkgs.python3Packages; [ icalendar recurring-ical-events tzdata ];
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/calendar-sync.py);
in {
  networking.hostName = "vm-120";

  fileSystems = nasMount stateDir "calendar";

  # one URL per line as "NAME|URL". Work Outlook and Proton both hand out a
  # published ICS link; StudIP exports one per calendar.
  sops.secrets.calendar-sources = {};
  # everything is served under a directory named after this token, so the
  # feed URLs are unguessable. Nothing else authenticates them.
  sops.secrets.calendar-token = {};
  # separate from the read token: a leaked feed URL must not also grant the
  # ability to overwrite a calendar.
  sops.secrets.calendar-upload-token = {};
  sops.secrets.kraken-api-key = {};
  sops.secrets.kraken-api-secret = {};

  systemd.services.calendar-sync = {
    description = "Merge remote calendars and render the TRMNL payload";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ calendarSync pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
    };
    environment = {
      CALENDAR_SOURCES = config.sops.secrets.calendar-sources.path;
      # a personal calendar is sparse: a short window renders an empty screen
      # whenever the next appointment is more than a fortnight out. Look far
      # ahead and cap the count instead, so the screen shows what is next.
      CALENDAR_HORIZON_DAYS = "90";
      CALENDAR_MAX_EVENTS = "12";
      KRAKEN_PAIRS = krakenPairs;
      KRAKEN_KEY_FILE = config.sops.secrets.kraken-api-key.path;
      KRAKEN_SECRET_FILE = config.sops.secrets.kraken-api-secret.path;
    };
    script = ''
      TOKEN=$(cat ${config.sops.secrets.calendar-token.path})
      [ -n "$TOKEN" ] || { echo "calendar-token is empty"; exit 1; }

      # serving from a directory named after the token keeps the secret out of
      # the nginx config, which Nix builds and validates in the world-readable
      # store.
      OUT="${publicDir}/$TOKEN"
      mkdir -p "$OUT"

      # drop stale token directories after a rotation.
      for dir in ${publicDir}/*; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$OUT" ] || rm -rf "$dir"
      done

      CALENDAR_OUT="$OUT" CALENDAR_UPLOAD_DIR=${uploadDir} calendar-sync
      chmod -R a+rX ${publicDir}
    '';
  };

  # nginx accepts PUT only into a directory named after the upload token, and
  # never creates one (no create_full_put_path), so a wrong token is a 409
  # rather than a write. Same trick as the read side: the token stays out of the
  # Nix store, which is world readable.
  systemd.services.calendar-upload-dir = {
    description = "Create the token-named upload directory";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    after = [ "remote-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 15; };
    script = ''
      TOKEN=$(cat ${config.sops.secrets.calendar-upload-token.path})
      [ -n "$TOKEN" ] || { echo "calendar-upload-token is empty"; exit 1; }
      DIR="${incomingDir}/$TOKEN"
      mkdir -p "$DIR" "${incomingDir}/.tmp" ${uploadDir}
      # drop stale token directories after a rotation.
      for dir in ${incomingDir}/*; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$DIR" ] || rm -rf "$dir"
      done
      chown -R nginx:nginx ${incomingDir}
      chown nginx:nginx ${uploadDir}
      chmod 700 ${incomingDir}
      chmod 700 "$DIR"
      # calendar-sync (root) reads the promoted files back as file:// sources.
      chmod 755 ${uploadDir}
    '';
  };

  # promote a pushed file to uploads/ as soon as it parses, then re-render so
  # the screen reflects the push within seconds instead of at the next timer.
  systemd.paths.calendar-upload = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      DirectoryNotEmpty = "${incomingDir}";
      MakeDirectory = false;
    };
  };
  systemd.services.calendar-upload = {
    description = "Validate a pushed .ics and re-render the calendar";
    path = [ promote pkgs.coreutils pkgs.findutils ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      # the PUT lands in the token directory; collect from any of them.
      find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -exec mv -t ${incomingDir} {} + 2>/dev/null || true
      calendar-promote ${incomingDir} ${uploadDir} || true
      chmod -R a+rX ${uploadDir} 2>/dev/null || true
      systemctl start --no-block calendar-sync.service
    '';
  };

  systemd.timers.calendar-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };

  services.nginx = {
    enable = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;

    virtualHosts.calendar = {
      default = true;
      listen = [{ addr = "0.0.0.0"; port = 80; }];
      root = publicDir;
      locations."~ \\.ics$".extraConfig = ''
        default_type text/calendar;
        add_header Cache-Control "no-cache";
      '';
      locations."~ \\.json$".extraConfig = ''
        default_type application/json;
        add_header Cache-Control "no-cache";
      '';

      # push endpoint for calendars that cannot be subscribed to:
      #   curl -T work.ics https://cal.lsck0.dev/upload/<upload-token>/work.ics
      # Only the names in uploadNames are accepted, only PUT, and only into the
      # token directory, which calendar-upload-dir creates. nginx refuses a PUT
      # whose parent directory is missing, so a wrong token cannot write.
      locations."~ ^/upload/[^/]+/(${lib.concatStringsSep "|" uploadNames})\\.ics$" = {
        root = incomingDir;
        extraConfig = ''
          limit_except PUT { deny all; }
          dav_methods PUT;
          dav_access user:rw group:r;
          client_max_body_size 8m;
          client_body_temp_path ${incomingDir}/.tmp;
          # a PUT arriving as /upload/<token>/work.ics must land in
          # <incomingDir>/<token>/work.ics, not <incomingDir>/upload/...
          rewrite ^/upload/(.*)$ /$1 break;
        '';
      };
    };
  };

  # Only the root-owned directory is a tmpfiles rule. The nginx-owned ones are
  # created by calendar-upload-dir below instead: /var/lib/calendar is an NFS
  # mount whose root is owned by `nobody`, and systemd-tmpfiles refuses to
  # descend into a child with a different owner -- "Detected unsafe path
  # transition ... (owned by nobody) -> ... (owned by nginx)", which fails the
  # whole nas-tmpfiles unit and with it the deploy.
  systemd.tmpfiles.rules = [
    "d ${publicDir} 0755 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
