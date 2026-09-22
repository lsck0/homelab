{ config, pkgs, lib, inventory, nasMount, ... }:
let
  # ---- TRMNL terminal feeds -----------------------------------------------
  # This VM is where the dashboards live, so it is also where the e-ink
  # terminal gets its data: Prometheus is local, which is the whole reason the
  # collector sits here rather than on its own host. Feeds are plain JSON under
  # an unguessable token, served on their own port and relayed out by the
  # external Traefik, because the TRMNL cloud polls them and cannot log in.
  terminalDir = "/var/lib/terminal";
  terminalPublic = "${terminalDir}/public";
  terminalPort = 8081;

  # the collector needs to know which VMs are meant to exist; Prometheus alone
  # cannot tell a retired target from a VM that is down right now.
  terminalInventory = pkgs.writeText "inventory.json" (builtins.toJSON inventory);

  statsSync = pkgs.writers.writePython3Bin "stats-sync" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/stats-sync.py);

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


  # only real VMs: down now, up sometime in the last 6h (the static /24 scrape
  # otherwise flags ~480 phantom IPs). On-demand VMs (instances.tf) sleep by
  # design and are excluded.
  onDemandIps = lib.mapAttrsToList (_: v: v.ip) (lib.filterAttrs (_: v: v.enabled == "onDemand") inventory);
  instanceDownExpr = "up{job=\"homelab-node-exporter\""
    + lib.optionalString (onDemandIps != []) ",instance!~\"(${lib.concatMapStringsSep "|" (ip: lib.replaceStrings [ "." ] [ "\\\\." ] ip) onDemandIps}):9100\""
    + "} == 0 and max_over_time(up{job=\"homelab-node-exporter\"}[6h]) > 0";
  subnetTargets = subnet:
    builtins.map (host: "${subnet}.${toString host}:9100") (lib.range 1 254);

  # A readable `vm` label on every node-exporter series ("homepage", not
  # "10.100.0.103:9100"). Names come from the inventory without the id/zone
  # prefix; the two Traefiks keep their zone. Unknown addresses keep the IP.
  shortName = v:
    let m = builtins.match "[0-9]+-(internal|external)-(.*)" v.name;
    in if m == null then v.name else builtins.elemAt m 1;
  nameCounts = lib.foldl' (acc: v: acc // { ${shortName v} = (acc.${shortName v} or 0) + 1; }) { } (lib.attrValues inventory);
  vmName = v: if nameCounts.${shortName v} > 1 then "${shortName v}-${v.type}" else shortName v;
  vmLabel = address: name: {
    source_labels = [ "__address__" ];
    regex = "${lib.replaceStrings [ "." ] [ "\\." ] address}:9100";
    target_label = "vm";
    replacement = name;
  };
  router = lib.findFirst (v: v.type == "router") null (lib.attrValues inventory);
  vmRelabels =
    [{ source_labels = [ "__address__" ]; regex = "([^:]+):.*"; target_label = "vm"; replacement = "$1"; }]
    ++ lib.mapAttrsToList (_: v: vmLabel v.ip (vmName v)) (lib.filterAttrs (_: v: v.type != "router") inventory)
    ++ lib.optionals (router != null) [ (vmLabel "10.100.0.1" "router") (vmLabel "10.200.0.1" "router") ]
    ++ [ (vmLabel "192.168.178.200" "proxmox") ];

  # alerts also go to the Hermes Telegram bot (same bot, same chat as Hermes).
  # needs telegram-bot-token + telegram-chat-id in sops (src/scripts/hermes-secrets.sh).
  enableTelegram = true;

  # ntfy topic for alerts. ntfy (vm-203) requires a login now, so Grafana
  # publishes as the `grafana` user; subscribe the phone with the `luca`
  # account. Change the topic name to rotate it.
  ntfyAlertTopic = "homelab-alerts";

  # ntfy renders these Go templates against Grafana's webhook JSON body
  # (?template=yes), so the phone shows a readable line instead of raw JSON.
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL "{{if eq .status \"firing\"}}FIRING{{else}}RESOLVED{{end}}: {{.commonLabels.alertname}}"}"
    "message=${lib.escapeURL "{{range .alerts}}{{.labels.vm}}{{if .annotations.summary}} - {{.annotations.summary}}{{end}}\n{{end}}"}"
    "tags=${lib.escapeURL "rotating_light"}"
  ];

  # Telegram message: one compact HTML block per alert instead of Grafana's
  # default wall of text. Firing and resolved are visually distinct.
  telegramMessage = ''
    {{ if eq .Status "firing" }}🔴 <b>FIRING</b>{{ else }}✅ <b>RESOLVED</b>{{ end }} · <b>{{ .CommonLabels.alertname }}</b>
    {{ range .Alerts }}
    {{ if .Labels.vm }}<code>{{ .Labels.vm }}</code>{{ else if .Labels.instance }}<code>{{ .Labels.instance }}</code>{{ end }}{{ if .Labels.severity }} [{{ .Labels.severity }}]{{ end }}
    {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ end }}
    {{ if .Annotations.description }}<i>{{ .Annotations.description }}</i>{{ end }}
    {{ end }}
    <a href="https://grafana.lsck0.dev/alerting/list">open Grafana</a>'';

  # single delivery path: Grafana unified alerting only. Prometheus' own
  # Alertmanager used to evaluate the same InstanceDown rule and notify the
  # same ntfy topic and Telegram chat, so every alert arrived twice.
  contactPoints = {
    apiVersion = 1;
    contactPoints = [{
      orgId = 1;
      name = "homelab-alerts";
      receivers = [{
        uid = "ntfy_cp";
        type = "webhook";
        settings = {
          url = "https://ntfy.lsck0.dev/${ntfyAlertTopic}?${ntfyQuery}";
          httpMethod = "POST";
          # ntfy denies anonymous publishing now (see 203-external-ntfy.nix).
          username = "grafana";
          password = config.sops.placeholder.ntfy-grafana-password;
        };
        disableResolveMessage = false;
      }] ++ lib.optional enableTelegram {
        uid = "telegram_cp";
        type = "telegram";
        settings = {
          bottoken = config.sops.placeholder.telegram-bot-token;
          chatid = config.sops.placeholder.telegram-chat-id;
          parse_mode = "HTML";
          message = telegramMessage;
          disable_web_page_preview = true;
        };
        disableResolveMessage = false;
      };
    }];
  };
in {
  networking.hostName = "vm-104";

  # bot token, chat id and the ntfy publisher password come from sops: rendered
  # into Grafana's contact point file at activation, never into the Nix store.
  sops.secrets = {
    ntfy-grafana-password = {};
    # calendar feeds, moved here with the rest of the dashboards
    calendar-sources = {};
    # separate from the read token: a leaked feed URL must not also grant the
    # ability to overwrite a calendar
    calendar-upload-token = {};
    kraken-api-key = {};
    kraken-api-secret = {};
  } // lib.optionalAttrs enableTelegram {
    telegram-bot-token = {};
    telegram-chat-id = {};
  };
  sops.templates."grafana-contact-points.yaml" = {
    owner = "grafana";
    content = builtins.toJSON contactPoints;
  };

  fileSystems = nasMount "/var/lib/grafana" "grafana"
    // nasMount "/var/lib/prometheus2" "prometheus"
    // nasMount "/var/lib/loki" "loki"
    # the terminal collector signs in to the qBittorrent API with the same
    # generated password the *arr stack uses
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens"
    // nasMount calendarState "calendar";

  # Loki: log aggregation for all VMs (promtail in base.nix pushes here)
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = 3100;
      # tempo also runs on this VM and defaults its gRPC to 9095; move Loki's
      # off it to avoid "bind: address already in use".
      server.grpc_listen_port = 9096;
      common = {
        instance_addr = "127.0.0.1";
        ring.kvstore.store = "inmemory";
        replication_factor = 1;
        path_prefix = "/var/lib/loki";
      };
      schema_config.configs = [{
        from = "2024-01-01";
        store = "tsdb";
        object_store = "filesystem";
        schema = "v13";
        index = { prefix = "index_"; period = "24h"; };
      }];
      storage_config.filesystem.directory = "/var/lib/loki/chunks";
      compactor = {
        working_directory = "/var/lib/loki/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config = {
        retention_period = "336h"; # 14 days
        volume_enabled = true;
        reject_old_samples = false;
      };
    };
  };

  # tempo: distributed tracing (OTLP), for services that emit spans
  services.tempo = {
    enable = true;
    settings = {
      server.http_listen_port = 3200;
      distributor.receivers.otlp.protocols = {
        grpc.endpoint = "0.0.0.0:4317";
        http.endpoint = "0.0.0.0:4318";
      };
      ingester.lifecycler.ring = { replication_factor = 1; kvstore.store = "inmemory"; };
      storage.trace = {
        backend = "local";
        local.path = "/var/lib/tempo/traces";
        wal.path = "/var/lib/tempo/wal";
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0750 loki loki -"
    "d /var/lib/tempo 0750 tempo tempo -"
    # /var/lib/grafana is a 0777 NFS share, so the database inherits 0644 and
    # Grafana logs "SQLite database file has broader permissions than it should"
    # on every start. Tighten the file itself (z = only if it exists).
    "z /var/lib/grafana/data/grafana.db 0640 grafana grafana -"
  ];

  services.prometheus = {
    enable = true;
    retentionTime = "30d";
    scrapeConfigs = [
      {
        job_name = "homelab-node-exporter";
        relabel_configs = vmRelabels;
        static_configs = [{
          targets =
            (subnetTargets "10.100.0")
            ++ (subnetTargets "10.200.0")
            ++ [
              "192.168.178.200:9100"
            ];
        }];
      }
      {
        # Traefik's own Prometheus endpoint (:8082) on both ingresses. Feeds the
        # HTTP analytics dashboard: request rate, status codes, latency.
        job_name = "traefik";
        static_configs = [{
          targets = [ "10.100.0.100:8082" "10.200.0.200:8082" ];
        }];
      }
    ];
    # no Prometheus-native alerting path: Grafana unified alerting below owns
    # every rule and every notification. Running both meant the same
    # InstanceDown rule notified the same ntfy topic and Telegram chat twice.
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 80;
        root_url = "https://grafana.lsck0.dev";
      };
      # access is gated by Authelia ForwardAuth on the Traefik route, which
      # injects the Remote-User header. Grafana trusts that header (auth.proxy)
      # instead of granting every anonymous visitor admin: so hitting
      # 10.100.0.104:80 directly, without the header, gets nothing.
      auth = {
        disable_login_form = true;
      };
      "auth.anonymous".enabled = false;
      "auth.proxy" = {
        enabled = true;
        header_name = "Remote-User";
        header_property = "username";
        auto_sign_up = true;
      };
      users = {
        allow_sign_up = false;
        # single-user lab: anyone Authelia lets through is the admin.
        auto_assign_org_role = "Admin";
      };
    };
    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://127.0.0.1:9090";
            uid = "prometheus";
            isDefault = true;
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://127.0.0.1:3100";
            uid = "loki";
          }
          {
            name = "Tempo";
            type = "tempo";
            access = "proxy";
            url = "http://127.0.0.1:3200";
            uid = "tempo";
          }
        ];
      };
      dashboards.settings = {
        providers = [
          {
            name = "Default";
            options.path = "/etc/grafana-dashboards";
          }
        ];
      };
      # alerting is always on and delivers to ntfy (vm-203, public, so it still
      # works when the LAN is down): subscribe the phone app to
      # https://ntfy.lsck0.dev/${ntfyAlertTopic} with the `luca` ntfy account.
      # Telegram is the second channel (enableTelegram).
      alerting = {
        # rendered by sops at activation with the secrets filled in. Not via
        # $__env{}: Grafana re-parses substituted values, turning the numeric
        # Telegram chat id into a number, and then refuses to start.
        contactPoints.path = config.sops.templates."grafana-contact-points.yaml".path;
        policies.settings = {
          apiVersion = 1;
          policies = [{
            orgId = 1;
            receiver = "homelab-alerts";
            group_by = [ "grafana_folder" "alertname" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
          }];
        };
        rules.settings = {
          apiVersion = 1;
          groups = [{
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = [{
              uid = "instance_down";
              title = "Instance down";
              condition = "C";
              # A node-exporter target that has been unreachable for 5m.
              data = [
                {
                  refId = "A";
                  relativeTimeRange = { from = 600; to = 0; };
                  datasourceUid = "prometheus";
                  model = {
                    refId = "A";
                    expr = instanceDownExpr;
                    instant = true;
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    refId = "C";
                    type = "threshold";
                    expression = "A";
                    # `up == 0 and …` keeps the value of `up`, so A is 0 for each
                    # real down target (and empty when everything is up).
                    conditions = [{
                      evaluator = { type = "lt"; params = [ 1 ]; };
                    }];
                  };
                }
              ];
              for = "5m";
              # empty result = nothing is down, not missing data.
              noDataState = "OK";
              execErrState = "Error";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.vm }} ({{ $labels.instance }}) stopped answering";
              annotations.description = "node-exporter on this VM has been unreachable for 5 minutes. Check `vm status <id>` on Proxmox and the VM's journal.";
            }
            {
              uid = "backup_stale";
              title = "NAS backup stale (dead-man)";
              condition = "C";
              # no successful daily backup for > 26h. no_data also fires, so a
              # backup box that stopped publishing the metric is caught too.
              data = [
                {
                  refId = "A";
                  relativeTimeRange = { from = 600; to = 0; };
                  datasourceUid = "prometheus";
                  model = {
                    refId = "A";
                    expr = "time() - max(homelab_backup_last_success_timestamp_seconds{type=\"daily\"})";
                    instant = true;
                  };
                }
                {
                  refId = "C";
                  datasourceUid = "__expr__";
                  model = {
                    refId = "C";
                    type = "threshold";
                    expression = "A";
                    conditions = [{
                      evaluator = { type = "gt"; params = [ 93600 ]; };
                    }];
                  };
                }
              ];
              for = "10m";
              noDataState = "Alerting";
              labels.severity = "critical";
              annotations.summary = "NAS daily backup has not succeeded in over 26h";
              annotations.description = "Kopia on vm-106 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server` and https://backup.lsck0.dev.";
            }];
          }];
        };
      };
    };
  };

  # one consolidated board: world map + HTTP + system + logs.
  environment.etc."grafana-dashboards/homelab.json".source = ../modules/dashboards/homelab.json;

  # Grafana's file provider only rescans at startup; restart when the dashboard changes.
  systemd.services.grafana.restartTriggers = [ ../modules/dashboards/homelab.json ];

  # 3100 Loki push, 3200 Tempo, 4317/4318 OTLP trace ingest.
  networking.firewall.allowedTCPPorts = [ 80 9090 3100 3200 4317 4318 terminalPort ];

  # Grafana trusts the Remote-User header (auth.proxy), so anyone who can reach
  # :80 directly can forge it and land as Admin. Prometheus (:9090) and Tempo
  # (:3200) have no authentication at all. Only the ingress and the ops hosts
  # may reach those three; 3100/4317/4318 stay open because every VM pushes
  # logs and traces into them.
  homelab.ingressOnly.ports = [ 80 9090 3200 terminalPort ];
  # the desktop status widget (arch-dotfiles quickshell homelab-status.py)
  # scrapes Prometheus straight from the LAN. That is read-only telemetry, so
  # it gets an exception; Grafana's :80 does not, because it trusts Remote-User
  # and anything that can reach it can forge an admin session.
  homelab.ingressOnly.portSources."9090" = [ "192.168.178.0/24" ];

  # ---- TRMNL terminal feeds -------------------------------------------------
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
      STATS_PROMETHEUS = "http://127.0.0.1:9090";
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
}
