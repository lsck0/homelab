{ config, pkgs, lib, inventory, nasMount, ... }:
let
  # Everything the e-ink terminal displays: the calendar, the homelab stats and
  # the arXiv feed. They started out scattered - the calendar had a VM of its
  # own and the other two were bolted onto the monitoring host - which meant
  # two hosts, two tokens and two sets of nginx rules for one screen.
  #
  # Every feed is plain JSON under one unguessable path, served on its own port
  # and relayed out by the external Traefik, because the TRMNL cloud polls them
  # and cannot log in.
  terminalDir = "/var/lib/terminal";
  terminalPublic = "${terminalDir}/public";
  terminalPort = 8081;

  # the collector needs to know which VMs are meant to exist; Prometheus alone
  # cannot tell a retired target from a VM that is down right now.
  terminalInventory = pkgs.writeText "inventory.json" (builtins.toJSON inventory);

  statsSync = pkgs.writers.writePython3Bin "stats-sync" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/stats-sync.py);

  githubSync = pkgs.writers.writePython3Bin "github-sync" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/github-sync.py);

  arxivSync = pkgs.writers.writePython3Bin "arxiv-sync" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/arxiv-sync.py);

  # ---- calendar, moved here from vm-120 -------------------------------------
  # The calendar is one dashboard among several now, so it lives with the rest
  # of them rather than on a host of its own. Its working state stays on the
  # same NAS share, so nothing had to be migrated; only the feed URLs moved.
  calendarState = "/var/lib/calendar";
  incomingDir = "${calendarState}/incoming";
  uploadDir = "${calendarState}/uploads";

  # kraken pair codes, not the display symbols: XXBTZEUR is BTC/EUR.
  krakenPairs = "XXBTZEUR,XETHZEUR";

  # Calendars that cannot be subscribed to, only exported by hand. The work
  # Outlook tenant blocks calendar publishing, so there is no URL to poll: the
  # .ics is pushed here instead and read back as a file:// source.
  uploadNames = [ "work" ];

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
  networking.hostName = "vm-104";

  # every feed's working state lives on the NAS, so this VM holds nothing that
  # matters: the calendar share came with the service when it moved off vm-120.
  fileSystems = nasMount calendarState "calendar"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  sops.secrets = {
    # one URL per line as "NAME|URL". Work Outlook and Proton both hand out a
    # published ICS link; StudIP exports one per calendar.
    calendar-sources = {};
    # separate from the read token: a leaked feed URL must not also grant the
    # ability to overwrite a calendar.
    calendar-upload-token = {};
    kraken-api-key = {};
    kraken-api-secret = {};
    # write token for the TRMNL plugins: it can replace what the panels show.
    trmnl-api-key = {};
    # read-only use here: the GitHub panel lists repos, CI state and open work.
    # Shared with the mirror job rather than minted separately, because it is
    # the same account and the same scopes.
    github-mirror-token = { owner = "nginx"; };
  };

  services.nginx = {
    enable = true;
    virtualHosts.terminal = {
      listen = [{ addr = "0.0.0.0"; port = terminalPort; }];
      root = terminalPublic;
      extraConfig = ''
        autoindex off;
        default_type application/json;
        add_header Cache-Control "no-store";
      '';
      locations."~ \\.ics$".extraConfig = ''
        default_type text/calendar;
        add_header Cache-Control "no-cache";
      '';

      # push endpoint for calendars that cannot be subscribed to:
      #   curl -T work.ics https://terminal.lsck0.dev/upload/<upload-token>/work.ics
      # Only the names in uploadNames are accepted, only PUT, and only into the
      # token directory, which calendar-upload-dir creates. nginx refuses a PUT
      # whose parent directory is missing, so a wrong token cannot write.
      locations."~ ^/upload/[^/]+/(${lib.concatStringsSep "|" uploadNames})\\.ics$" = {
        root = incomingDir;
        # must be emitted before any other regex location: nginx takes the
        # first match, and a static handler answers a PUT with 405.
        priority = 100;
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

  systemd.services.terminal-token = {
    description = "Create the terminal feed directory and its access token";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" "terminal-sync.service" ];
    path = [ pkgs.coreutils pkgs.openssl ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      mkdir -p ${terminalDir}
      if [ ! -s ${terminalDir}/token ]; then
        openssl rand -hex 24 | tr -d '\n' > ${terminalDir}/token
      fi
      TOKEN=$(cat ${terminalDir}/token)
      mkdir -p ${terminalPublic}/$TOKEN
      # the collector runs as nginx and writes into the token directory, so
      # nginx has to own the whole path, not just the leaf
      chown -R nginx:nginx ${terminalDir}
      chmod 750 ${terminalDir}
      echo "terminal feed: https://terminal.lsck0.dev/$TOKEN/stats.json"
    '';
  };

  systemd.services.terminal-sync = {
    description = "Collect homelab stats for the TRMNL terminal";
    after = [ "terminal-token.service" "network-online.target" ];
    requires = [ "terminal-token.service" ];
    wants = [ "network-online.target" ];
    path = [ statsSync pkgs.coreutils ];
    environment = {
      STATS_PROMETHEUS = "http://10.100.0.105:9090";
      STATS_INVENTORY = "${terminalInventory}";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "nginx";
      Group = "nginx";
    };
    script = ''
      stats-sync ${terminalPublic}/$(cat ${terminalDir}/token)
    '';
  };

  # arXiv announces once a day, so hourly is already generous; it exists to
  # catch the batch soon after it lands rather than to poll for changes.
  systemd.services.arxiv-sync = {
    description = "Fetch today's arXiv mathematics announcements";
    after = [ "terminal-token.service" "network-online.target" ];
    requires = [ "terminal-token.service" ];
    wants = [ "network-online.target" ];
    path = [ arxivSync pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "nginx";
      Group = "nginx";
    };
    script = ''
      arxiv-sync ${terminalPublic}/$(cat ${terminalDir}/token)
    '';
  };

  # The .liquid files in this repo are the dashboards, and nothing used to
  # carry them anywhere - every change was uploaded by hand. That made the
  # panels the one part of the lab whose visible behaviour lived outside git:
  # rebuild from scratch and they would keep whatever had last been pasted in.
  #
  # Plugin ids come from the TRMNL account and are not derivable from
  # anything here, so they are written down. A plugin created later needs a
  # line adding; nothing else does.
  systemd.services.trmnl-sync = {
    description = "Push the dashboard templates to TRMNL";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    serviceConfig = {
      Type = "oneshot";
      # TRMNL is someone else's service; a bad afternoon there should not
      # leave the templates permanently unsent.
      Restart = "on-failure";
      RestartSec = 600;
      TimeoutStartSec = "10min";
    };
    environment.TRMNL_API_KEY_FILE = config.sops.secrets.trmnl-api-key.path;
    script = ''
      exec python3 ${../scripts/trmnl-sync.py} \
        484687=${../modules/trmnl/terminal.liquid} \
        484717=${../modules/trmnl/arxiv.liquid} \
        487323=${../modules/trmnl/github.liquid} \
        484254=${../modules/trmnl/calendar.liquid} \
        484274=${../modules/trmnl/calendar.liquid} \
        484257=${../modules/trmnl/calendar.liquid} \
        484255=${../modules/trmnl/calendar.liquid}
    '';
  };

  # On boot and daily. The templates change when someone edits them and a
  # deploy restarts this unit, so the timer is only a backstop for a push
  # that failed while TRMNL was unreachable.
  systemd.timers.trmnl-sync = {
    description = "Keep the TRMNL plugins on this repo's templates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "24h";
      Persistent = true;
      Unit = "trmnl-sync.service";
    };
  };

  # GitHub: commits, repos, CI state and open work. Hourly - the panel is a
  # glance at the day, not a notifier, and six API calls an hour is nothing
  # against the 5000 limit.
  systemd.services.github-sync = {
    description = "Collect GitHub activity for the TRMNL terminal";
    after = [ "terminal-token.service" "network-online.target" ];
    requires = [ "terminal-token.service" ];
    wants = [ "network-online.target" ];
    path = [ githubSync pkgs.coreutils ];
    environment.GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
    serviceConfig = {
      Type = "oneshot";
      User = "nginx";
      Group = "nginx";
    };
    script = ''
      github-sync ${terminalPublic}/$(cat ${terminalDir}/token)
    '';
  };

  systemd.timers.github-sync = {
    description = "Refresh the GitHub feed for the terminal";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "7m";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "github-sync.service";
    };
  };

  systemd.timers.arxiv-sync = {
    description = "Refresh the arXiv feed for the terminal";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5m";
      OnUnitActiveSec = "1h";
      Persistent = true;
      Unit = "arxiv-sync.service";
    };
  };

  systemd.services.calendar-sync = {
    description = "Merge remote calendars and render the TRMNL payload";
    after = [ "terminal-token.service" "network-online.target" ];
    requires = [ "terminal-token.service" ];
    wants = [ "network-online.target" ];
    path = [ calendarSync pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
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
      OUT=${terminalPublic}/$(cat ${terminalDir}/token)
      mkdir -p "$OUT"
      CALENDAR_OUT="$OUT" CALENDAR_UPLOAD_DIR=${uploadDir} calendar-sync
      chown -R nginx:nginx "$OUT"
      chmod -R a+rX ${terminalPublic}
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
      # calendar-sync reads the promoted files back as file:// sources.
      chmod 755 ${uploadDir}
    '';
  };

  # the NixOS nginx unit runs with ProtectSystem=strict, so the whole filesystem
  # is read-only to it apart from an allowlist. Without this the DAV PUT fails
  # with "open() ... failed (30: Read-only file system)" and returns 500.
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ incomingDir terminalDir ];

  # promote a pushed file to uploads/ as soon as it parses, then re-render so
  # the screen reflects the push within seconds instead of at the next timer.
  # A timer, not a systemd.path: the PUT lands in incoming/<token>/, and
  # DirectoryNotEmpty on incoming/ is satisfied permanently by that token
  # directory, so it never fires again after the first boot. Watching the token
  # directory itself is not possible either, since its name is a secret and unit
  # files are built into the world-readable Nix store.
  systemd.timers.calendar-upload = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "1min";
      AccuracySec = "10s";
    };
  };
  systemd.services.calendar-upload = {
    description = "Validate a pushed .ics and re-render the calendar";
    path = [ promote pkgs.coreutils pkgs.findutils pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      # nothing pushed since the last run: do not re-render, or the timer would
      # refetch every remote calendar once a minute instead of every 15.
      [ -n "$(find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -print -quit)" ] || exit 0

      # the PUT lands in the token directory; collect from any of them.
      find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -exec mv -t ${incomingDir} {} + 2>/dev/null || true
      calendar-promote ${incomingDir} ${uploadDir} || true
      chmod -R a+rX ${uploadDir} 2>/dev/null || true
      systemctl start --no-block calendar-sync.service
    '';
  };

  systemd.timers.terminal-sync = {
    description = "Refresh the TRMNL terminal feed";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "2m";
      Unit = "terminal-sync.service";
    };
  };

  networking.firewall.allowedTCPPorts = [ terminalPort ];

  # the feeds carry no secret beyond the token in their path, but there is no
  # reason for anything except the ingress to read them.
  homelab.ingressOnly.ports = [ terminalPort ];
}
