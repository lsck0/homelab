# e-ink terminal: calendar, lab stats, arxiv, energy and github feeds for the TRMNL cloud
{ config, pkgs, lib, inventory, site, nasMount, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  telemetry = import ../../modules/telemetry.nix { inherit lib inventory; };
  energyModel = import ../../modules/energy { inherit pkgs; };
  feedIo = import ../../modules/feeds { inherit pkgs; };
  edge = net.zones.external.ingress;
  qbittorrent = catalog.internal.qbittorrent;

  terminalDir = "/var/lib/terminal";
  # nginx's root: one directory per feed, named by the feed's token
  terminalPublic = "${terminalDir}/public";
  # the collectors' stable paths: feed name -> its token directory
  feedLinks = "${terminalDir}/feeds";
  # every feed's urls, for the owner to paste into TRMNL; root only, never in the journal
  feedUrls = "${terminalDir}/feeds.txt";
  terminalRoute = catalog.internal.terminal;
  calendarRoute = catalog.internal.calendar;
  feedDir = name: "${feedLinks}/${name}";

  # stats-sync names guests as grafana does (modules/telemetry.nix) and needs to know which should exist
  terminalInventory = pkgs.writeText "inventory.json"
    (builtins.toJSON (lib.mapAttrs (_: v: v // { vm = telemetry.vmName v; }) inventory));

  python = name: libraries: pkgs.writers.writePython3Bin name { inherit libraries; flakeIgnore = [ "E501" ]; };
  pythonScript = name: libraries: python name libraries (builtins.readFile ./lib/${name}.py);

  energyState = "/var/lib/energy-sync";
  inherit (config.homelab) textfileDir;

  /*
    feeds: everything the terminal publishes, one entry per feed. A new TRMNL panel is one entry here, its
    template in lib/trmnl/, and the plugin in TRMNL's cloud (Polling URL = the feed's url from feedUrls).

      files        what the feed directory holds, as published
      cloud        what TRMNL's cloud receives from it; null for a feed TRMNL never sees
      plugins      TRMNL plugin id -> the template trmnl-sync pushes to it
      route        the catalog route its urls use, terminal by default
      script       lib/<script>.py, run as nginx by a timer; a feed without one is written by another's
      libraries    python packages the script imports
      arguments    its command line, the feed's directory by default
      environment, timer, description   the unit's
      stateDirectory  /var/lib/<name>, kept across runs
      exports      files of its state directory installed as node-exporter textfiles after each run

    Every feed has its own token, HMAC-SHA256 of the terminal-token secret and the feed's name: a leaked plugin
    url opens that one feed, and the private calendar (ics) sits on a token TRMNL never sees.
  */
  feeds = {
    stats = {
      files = [ "stats.json" ];
      cloud = "guest names, load and state; request counts per route; visitor countries, agents and host names "
        + "of the public ingress; disk use; torrent counts and progress, without names";
      plugins."484687" = ./lib/trmnl/terminal.liquid;
      script = "stats-sync";
      libraries = [ feedIo ];
      description = "Collect homelab stats for the TRMNL terminal";
      environment = {
        STATS_PROMETHEUS = telemetry.urls.prometheus;
        STATS_LOKI = telemetry.urls.loki;
        STATS_QBITTORRENT = "http://${net.ipOf (toString qbittorrent.vmid)}:${toString qbittorrent.port}";
        STATS_INVENTORY = "${terminalInventory}";
        STATS_TOKENS = config.homelab.tokens.dir;
        STATS_CLIENT_INGRESS = "vm-${edge}";
        STATS_EDGE_ADDRESS = net.ipOf edge;
        STATS_CLIENT_DOMAIN = ".${net.domain}";
      };
      timer = { OnBootSec = "2m"; OnUnitActiveSec = "2m"; };
    };
    # house power, gas, water, prices; the panel refreshes every few minutes, power is a snapshot anyway
    energy = {
      files = [ "energy.json" ];
      cloud = "house power, energy and cost, meter readings and when they were read: whether someone is home";
      plugins."2f3cbe6f-8b44-46fe-90a2-86d4d2543280" = ./lib/trmnl/energy.liquid;
      script = "energy-sync";
      libraries = [ energyModel feedIo ];
      arguments = [ (feedDir "energy") energyState ];
      stateDirectory = baseNameOf energyState;
      # the board's per-day and per-month bars (instances/105-internal-grafana/lib/dashboards/energy.py)
      exports = [ "energy.prom" ];
      description = "Collect house energy for the TRMNL terminal";
      environment.ENERGY_PROMETHEUS = telemetry.urls.prometheus;
      timer = { OnBootSec = "3m"; OnUnitActiveSec = "5m"; };
    };
    # arxiv announces daily, hourly catches the batch
    arxiv = {
      files = [ "arxiv.json" ];
      cloud = "today's arXiv mathematics announcements, public data";
      plugins."484717" = ./lib/trmnl/arxiv.liquid;
      script = "arxiv-sync";
      libraries = [ feedIo ];
      description = "Fetch today's arXiv mathematics announcements";
      timer = { OnBootSec = "5m"; OnUnitActiveSec = "1h"; Persistent = true; };
    };
    github = {
      files = [ "github.json" ];
      cloud = "the owner's public GitHub repos, their ci failures, open issues and pull requests, commit counts";
      plugins."487323" = ./lib/trmnl/github.liquid;
      script = "github-sync";
      libraries = [ feedIo ];
      description = "Collect GitHub activity for the TRMNL terminal";
      environment.GITHUB_TOKEN_FILE = config.sops.secrets.github-mirror-token.path;
      timer = { OnBootSec = "7m"; OnUnitActiveSec = "1h"; Persistent = true; };
    };
    calendar = {
      files = [ "week.json" "week-prev.json" "week-next.json" "day.json" "day-next.json" "month.json" "month-next.json" ];
      cloud = "event titles, times and locations of every calendar source; no descriptions, attendees or links";
      # one template for the week, day and month plugins; each polls the view its TRMNL settings name
      plugins = lib.genAttrs [ "484254" "484274" "484257" "484255" ] (_: ./lib/trmnl/calendar.liquid);
      script = "calendar-sync";
      libraries = with pkgs.python3Packages; [ icalendar recurring-ical-events tzdata feedIo ];
      arguments = [ (feedDir "calendar") (feedDir "ics") ];
      description = "Merge remote calendars and render the TRMNL payload";
      environment = {
        CALENDAR_SOURCES = config.sops.secrets.calendar-sources.path;
        CALENDAR_UPLOAD_DIR = uploadDir;
        CALENDAR_TZ = site.timeZone;
      };
      timer = { OnBootSec = "2min"; OnUnitActiveSec = "15min"; Persistent = true; };
    };
    # every source merged in full for the owner's own calendar apps; calendar-sync writes it, no plugin holds its token
    ics = {
      files = [ "merged.ics" ];
      cloud = null;
      plugins = { };
      route = calendarRoute;
    };
  };
  collectors = lib.filterAttrs (_: f: f ? script) feeds;

  # creates the token directories and the links, drops stale ones, and writes feedUrls
  terminalFeeds = python "terminal-feeds" [ ] ''
    import hashlib
    import hmac
    import json
    import os
    import shutil
    import sys

    secret_path, public, links, urls_path, spec = sys.argv[1:]
    with open(secret_path, "rb") as handle:
        secret = handle.read().strip()
    if not secret:
        sys.exit(f"{secret_path} is empty")
    feeds = json.loads(spec)

    os.makedirs(public, exist_ok=True)
    os.makedirs(links, exist_ok=True)
    tokens = {name: hmac.new(secret, name.encode(), hashlib.sha256).hexdigest() for name in feeds}
    for name, token in tokens.items():
        directory = os.path.join(public, token)
        os.makedirs(directory, exist_ok=True)
        shutil.chown(directory, "nginx", "nginx")
        link = os.path.join(links, name)
        if os.path.islink(link) or os.path.exists(link):
            os.remove(link)
        os.symlink(directory, link)
    # a rotated secret or a removed feed leaves no readable directory behind
    for entry in os.listdir(public):
        if entry not in tokens.values():
            shutil.rmtree(os.path.join(public, entry))
    for entry in os.listdir(links):
        if entry not in tokens:
            os.remove(os.path.join(links, entry))

    lines = [f"{name}: {f['base']}/{tokens[name]}/{file}" for name, f in sorted(feeds.items()) for file in f["files"]]
    fd = os.open(urls_path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.replace(urls_path + ".tmp", urls_path)
    print(f"{len(tokens)} feeds published, urls in {urls_path}")
  '';
  feedSpec = builtins.toJSON (lib.mapAttrs (_: f: {
    inherit (f) files;
    base = "https://${net.fqdn (f.route or terminalRoute).host}";
  }) feeds);

  # trmnl-sync's arguments: <plugin id>=<template> for every plugin of every feed
  pluginTemplates = lib.concatLists (lib.mapAttrsToList (_: f: lib.mapAttrsToList (id: template: "${id}=${template}") f.plugins) feeds);

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
            with open(src, "rb") as handle:
                calendar = Calendar.from_ical(handle.read())
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
in {
  networking.hostName = "vm-104";

  # stats-sync reads the torrent client's queue
  homelab.tokens.reads = [ "qbittorrent-user" "qbittorrent-pass" ];
  # footers and "today" in the payloads are the house's local time
  time.timeZone = site.timeZone;

  # feed state on the nas, vm is disposable
  homelab.nasMounts = nasMount calendarState "calendar";

  imports = [
    # an lxc mounts nfs at boot, not on access: nothing may run before the shares are up
    {
      systemd.services = lib.genAttrs ([
        "nginx" "trmnl-sync" "calendar-upload-dir" "calendar-upload"
      ] ++ map (f: f.script) (lib.attrValues collectors)) (_: {
        unitConfig.RequiresMountsFor = [ calendarState ] ++ config.homelab.tokens.mountPoints;
      });
    }
    {
      systemd.services = lib.mapAttrs' (name: f: lib.nameValuePair f.script {
        inherit (f) description;
        environment = f.environment or { };
        after = [ "terminal-token.service" "network-online.target" ];
        requires = [ "terminal-token.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "nginx";
          Group = "nginx";
          ExecStart = lib.escapeShellArgs ([ "${pythonScript f.script (f.libraries or [ ])}/bin/${f.script}" ]
            ++ f.arguments or [ (feedDir name) ]);
        } // lib.optionalAttrs (f ? stateDirectory) {
          StateDirectory = f.stateDirectory;
        } // lib.optionalAttrs (f ? exports) {
          # node-exporter's textfile dir belongs to root
          ExecStartPost = map (file:
            "+${pkgs.coreutils}/bin/install -m 0644 /var/lib/${f.stateDirectory}/${file} ${textfileDir}/${file}") f.exports;
        };
      }) collectors;
      systemd.timers = lib.mapAttrs' (_: f: lib.nameValuePair f.script {
        wantedBy = [ "timers.target" ];
        timerConfig = f.timer;
      }) collectors;
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
    # every feed's token derives from it; from sops so a rebuilt guest keeps the plugin urls
    terminal-token = {};
  };

  services.nginx = {
    enable = true;
    virtualHosts.terminal = {
      listen = [{ addr = "0.0.0.0"; port = terminalRoute.port; }];
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

  systemd.services.terminal-token = {
    description = "Publish the terminal feeds under their tokens";
    wantedBy = [ "multi-user.target" ];
    before = [ "nginx.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      install -d -m 0755 ${terminalDir}
      ${terminalFeeds}/bin/terminal-feeds ${config.sops.secrets.terminal-token.path} ${terminalPublic} ${feedLinks} \
        ${feedUrls} ${lib.escapeShellArg feedSpec}
    '';
  };

  # this repo's .liquid files are the dashboards
  systemd.services.trmnl-sync = {
    description = "Push the dashboard templates to TRMNL";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # trmnl outages should not strand stale templates
      Restart = "on-failure";
      RestartSec = 600;
      TimeoutStartSec = "10min";
    };
    environment.TRMNL_API_KEY_FILE = config.sops.secrets.trmnl-api-key.path;
    script = "exec ${pythonScript "trmnl-sync" [ ]}/bin/trmnl-sync ${lib.escapeShellArgs pluginTemplates}";
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

  # promote a pushed file once it parses: the push itself starts it, nothing polls
  systemd.paths.calendar-upload = {
    wantedBy = [ "paths.target" ];
    pathConfig.PathExistsGlob = "${incomingDir}/*/*.ics";
  };
  systemd.services.calendar-upload = {
    description = "Validate a pushed .ics and re-render the calendar";
    path = [ promote pkgs.coreutils pkgs.findutils pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      # collect from any token dir
      find ${incomingDir} -mindepth 2 -maxdepth 2 -name '*.ics' -exec mv -t ${incomingDir} {} +
      # a rejected push is an operating error: promote names it and keeps the previous copy, the rest still renders
      calendar-promote ${incomingDir} ${uploadDir} || echo "calendar-upload: a pushed calendar was rejected"
      chmod -R a+rX ${uploadDir}
      systemctl start --no-block calendar-sync.service
    '';
  };

  networking.firewall.allowedTCPPorts = [ terminalRoute.port ];

  # every feed carries no secret beyond its path token
  homelab.ingressOnly.ports = [ terminalRoute.port ];
}
