{ config, pkgs, lib, inventory, nasMount, ... }:
let
  # e-ink terminal: calendar, lab stats, arxiv, energy
  terminalDir = "/var/lib/terminal";
  terminalPublic = "${terminalDir}/public";
  terminalPort = 8081;

  # prometheus cannot tell which vms should exist
  terminalInventory = pkgs.writeText "inventory.json" (builtins.toJSON inventory);

  python = name: libraries: pkgs.writers.writePython3Bin name { inherit libraries; flakeIgnore = [ "E501" ]; };
  pythonScript = name: libraries: python name libraries (builtins.readFile ../scripts/${name}.py);

  # the token-named dir the feeds are served from
  feedDir = "${terminalPublic}/$(cat ${terminalDir}/token)";
  prometheus = "http://10.100.0.105:9090";

  # feed collectors, ../scripts/<bin>.py run as nginx into feedDir
  collectors = {
    terminal-sync = {
      bin = "stats-sync";
      description = "Collect homelab stats for the TRMNL terminal";
      environment = { STATS_PROMETHEUS = prometheus; STATS_INVENTORY = "${terminalInventory}"; };
      timer = { OnBootSec = "2m"; OnUnitActiveSec = "2m"; };
    };
    # house power, gas, water, prices; the panel refreshes every few minutes, power is a snapshot anyway
    energy-sync = {
      bin = "energy-sync";
      description = "Collect house energy for the TRMNL terminal";
      environment.ENERGY_PROMETHEUS = prometheus;
      timer = { OnBootSec = "3m"; OnUnitActiveSec = "5m"; };
    };
    # arxiv announces daily, hourly catches the batch
    arxiv-sync = {
      bin = "arxiv-sync";
      description = "Fetch today's arXiv mathematics announcements";
      environment = { };
      timer = { OnBootSec = "5m"; OnUnitActiveSec = "1h"; Persistent = true; };
    };
    # github: commits, repos, ci, open work
    github-sync = {
      bin = "github-sync";
      description = "Collect GitHub activity for the TRMNL terminal";
      environment.GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
      timer = { OnBootSec = "7m"; OnUnitActiveSec = "1h"; Persistent = true; };
    };
  };

  # calendar is one dashboard among several
  calendarState = "/var/lib/calendar";
  incomingDir = "${calendarState}/incoming";
  uploadDir = "${calendarState}/uploads";


  # calendars only exported by hand
  uploadNames = [ "work" ];

  promote = python "calendar-promote" [ pkgs.python3Packages.icalendar ] ''
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
          except Exception as err:  # noqa: BLE001, keep the good copy
              print(f"{entry}: not a calendar ({err}), keeping the previous copy")
              rc = 1
              os.replace(src, src + ".rejected")
              continue
          shutil.move(src, os.path.join(uploads, entry))
          print(f"{entry}: accepted, {len(events)} events")

      sys.exit(rc)
  '';

  calendarSync = pythonScript "calendar-sync" (with pkgs.python3Packages; [ icalendar recurring-ical-events tzdata ]);
in {
  networking.hostName = "vm-104";
  # footers and "today" in the payloads are local time
  time.timeZone = "Europe/Berlin";

  # feed state on the nas, vm is disposable
  fileSystems = nasMount calendarState "calendar"
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  imports = [
    # an lxc mounts nfs at boot, not on access: nothing may run before the shares are up
    {
      systemd.services = lib.genAttrs ([
        "nginx" "trmnl-sync" "calendar-sync" "calendar-upload-dir" "calendar-upload"
      ] ++ lib.attrNames collectors) (_: { unitConfig.RequiresMountsFor = [ calendarState "/var/lib/homepage-tokens" ]; });
    }
    {
      systemd.services = lib.mapAttrs (_: c: {
        inherit (c) description environment;
        after = [ "terminal-token.service" "network-online.target" ];
        requires = [ "terminal-token.service" ];
        wants = [ "network-online.target" ];
        path = [ (pythonScript c.bin [ ]) pkgs.coreutils ];
        serviceConfig = { Type = "oneshot"; User = "nginx"; Group = "nginx"; };
        script = "${c.bin} ${feedDir}";
      }) collectors;
      systemd.timers = lib.mapAttrs (_: c: { wantedBy = [ "timers.target" ]; timerConfig = c.timer; }) collectors;
    }
  ];

  sops.secrets = {
    # "NAME|URL" per line
    calendar-sources = { owner = "nginx"; };
    # leaked feed url must not grant uploads
    calendar-upload-token = {};
    # trmnl write token, can replace panels
    trmnl-api-key = {};
    # read-only: github panel
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

      # push endpoint: curl -T work.ics
      locations."~ ^/upload/[^/]+/(${lib.concatStringsSep "|" uploadNames})\\.ics$" = {
        root = incomingDir;
        # nginx takes the first matching regex
        priority = 100;
        extraConfig = ''
          limit_except PUT { deny all; }
          dav_methods PUT;
          dav_access user:rw group:r;
          client_max_body_size 8m;
          client_body_temp_path ${incomingDir}/.tmp;
          # /upload/<token>/x.ics -> <incomingDir>/<token>/x.ics
          rewrite ^/upload/(.*)$ /$1 break;
        '';
      };
    };
  };

  sops.secrets.terminal-token = {};

  systemd.services.terminal-token = {
    description = "Create the terminal feed directory and place its access token";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" "terminal-sync.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      mkdir -p ${terminalDir}
      # the token is in the trmnl plugin urls; from sops so a rebuilt guest keeps them working
      install -m 600 ${config.sops.secrets.terminal-token.path} ${terminalDir}/token
      TOKEN=$(cat ${terminalDir}/token)
      mkdir -p ${terminalPublic}/$TOKEN
      # collector runs as nginx, owns the whole path
      chown -R nginx:nginx ${terminalDir}
      chmod 750 ${terminalDir}
      echo "terminal feed: https://terminal.lsck0.dev/$TOKEN/stats.json"
    '';
  };

  systemd.services.calendar-sync = {
    description = "Merge remote calendars and render the TRMNL payload";
    after = [ "terminal-token.service" "network-online.target" ];
    requires = [ "terminal-token.service" ];
    wants = [ "network-online.target" ];
    path = [ calendarSync pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; User = "nginx"; Group = "nginx"; };
    environment = {
      CALENDAR_SOURCES = config.sops.secrets.calendar-sources.path;
      CALENDAR_UPLOAD_DIR = uploadDir;
    };
    script = "CALENDAR_OUT=${feedDir} calendar-sync";
  };

  systemd.timers.calendar-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };

  # this repo's .liquid files are the dashboards
  systemd.services.trmnl-sync = {
    description = "Push the dashboard templates to TRMNL";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.python3 ];
    serviceConfig = {
      Type = "oneshot";
      # trmnl outages should not strand stale templates
      Restart = "on-failure";
      RestartSec = 600;
      TimeoutStartSec = "10min";
    };
    environment.TRMNL_API_KEY_FILE = config.sops.secrets.trmnl-api-key.path;
    script = ''
      exec python3 ${../scripts/trmnl-sync.py} \
        484687=${../modules/trmnl/terminal.liquid} \
        2f3cbe6f-8b44-46fe-90a2-86d4d2543280=${../modules/trmnl/energy.liquid} \
        484717=${../modules/trmnl/arxiv.liquid} \
        487323=${../modules/trmnl/github.liquid} \
        484254=${../modules/trmnl/calendar.liquid} \
        484274=${../modules/trmnl/calendar.liquid} \
        484257=${../modules/trmnl/calendar.liquid} \
        484255=${../modules/trmnl/calendar.liquid}
    '';
  };

  systemd.timers.trmnl-sync = {
    description = "Keep the TRMNL plugins on this repo's templates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10m";
      OnUnitActiveSec = "24h";
      Persistent = true;
    };
  };

  # nginx puts only into the token-named dir
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
      # drop stale token dirs after rotation
      for dir in ${incomingDir}/*; do
        [ -d "$dir" ] || continue
        [ "$dir" = "$DIR" ] || rm -rf "$dir"
      done
      chown -R nginx:nginx ${incomingDir}
      chown nginx:nginx ${uploadDir}
      chmod 700 ${incomingDir}
      chmod 700 "$DIR"
      # calendar-sync reads these as file:// sources
      chmod 755 ${uploadDir}
    '';
  };

  # nginx unit has ProtectSystem=strict
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ incomingDir ];

  # promote a pushed file once it parses
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
      # nothing pushed: skip, else refetch every minute
      [ -n "$(find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -print -quit)" ] || exit 0

      # collect from any token dir
      find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -exec mv -t ${incomingDir} {} + 2>/dev/null || true
      calendar-promote ${incomingDir} ${uploadDir} || true
      chmod -R a+rX ${uploadDir} 2>/dev/null || true
      systemctl start --no-block calendar-sync.service
    '';
  };

  networking.firewall.allowedTCPPorts = [ terminalPort ];

  # feeds carry no secret beyond the path token
  homelab.ingressOnly.ports = [ terminalPort ];
}
