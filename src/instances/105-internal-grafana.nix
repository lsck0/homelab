{ config, pkgs, lib, inventory, nasMount, ... }:
let


  # guests meant to run only: onDemand ones sleep and disabled ones are off on purpose; down now, up within 6h
  notRunningIps = lib.mapAttrsToList (_: v: v.ip) (lib.filterAttrs (_: v: v.enabled != "true") inventory);
  instanceDownExpr = "up{job=\"homelab-node-exporter\""
    + lib.optionalString (notRunningIps != []) ",instance!~\"(${lib.concatMapStringsSep "|" (ip: lib.replaceStrings [ "." ] [ "\\\\." ] ip) notRunningIps}):9100\""
    + "} == 0 and max_over_time(up{job=\"homelab-node-exporter\"}[6h]) > 0";

  # readable `vm` label, not ip:port
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
    ++ lib.optional (router != null) (vmLabel "10.100.0.1" "router")
    ++ [ (vmLabel "192.168.178.200" "proxmox") ];

  # blackbox probes
  # probe backends, public names always 302 via authelia
  routes = import ../modules/routes.nix;
  probes =
    let
      # on-demand/disabled vms would alarm forever
      alwaysOn = r: (inventory.${toString r.vmid}.enabled or "false") == "true"
        && (r.monitor or true);
      ofSide = side: lib.mapAttrsToList (name: r: {
        inherit name;
        url = "${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}${r.health or ""}";
      }) (lib.filterAttrs (_: alwaysOn) side);
    in
    lib.concatLists (lib.mapAttrsToList (_: ofSide) routes)
    # the ingresses own no route
    ++ [
      { name = "traefik-internal"; url = "http://10.100.0.100:80"; }
      { name = "traefik-external"; url = "http://10.200.0.200:80"; }
    ];

  # alerts also go to hermes telegram
  enableTelegram = true;

  # ntfy (vm-203) requires a login
  ntfyAlertTopic = "homelab-alerts";

  # ntfy renders go templates on the webhook body
  ntfyQuery = lib.concatStringsSep "&" [
    "template=yes"
    "title=${lib.escapeURL "{{if eq .status \"firing\"}}FIRING{{else}}RESOLVED{{end}}: {{.commonLabels.alertname}}"}"
    "message=${lib.escapeURL "{{range .alerts}}{{.labels.vm}}{{if .annotations.summary}} - {{.annotations.summary}}{{end}}\n{{end}}"}"
    "tags=${lib.escapeURL "rotating_light"}"
  ];

  # one header per category and one line per alert; html-escaped, an unescaped "<id>" once made
  # telegram reject every message with 400
  telegramMessage = ''
    {{ if .Alerts.Firing }}🔴 <b>{{ .CommonAnnotations.firing | html }}</b>
    {{ range .Alerts.Firing }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}{{ if .Alerts.Resolved }}✅ <b>{{ .CommonAnnotations.resolved | html }}</b>
    {{ range .Alerts.Resolved }}• {{ .Annotations.summary | html }}
    {{ end }}{{ end }}'';

  # grafana-managed rule, one query A thresholded by C
  mkRule = r: {
    inherit (r) uid title;
    condition = "C";
    data = [
      {
        refId = "A";
        relativeTimeRange = { from = r.range or 600; to = 0; };
        datasourceUid = r.datasource or "prometheus";
        model = { refId = "A"; expr = r.expr; instant = true; }
          // lib.optionalAttrs ((r.datasource or "") == "loki") { queryType = "instant"; };
      }
      {
        refId = "C";
        datasourceUid = "__expr__";
        model = {
          refId = "C";
          type = "threshold";
          expression = "A";
          conditions = [{ evaluator = { type = r.op or "gt"; params = [ r.threshold ]; }; }];
        };
      }
    ];
    for = r.for or "5m";
    noDataState = r.noData or "OK";
    execErrState = "Error";
    labels = { severity = r.severity or "critical"; } // lib.optionalAttrs (r.telegram or true) { notify = "telegram"; };
    annotations = { inherit (r) firing resolved summary description; };
  };

  # single delivery path: Grafana unified alerting
  contactPoints = {
    apiVersion = 1;
    contactPoints = [{
      orgId = 1;
      name = "ntfy";
      receivers = [{
        uid = "ntfy_cp";
        type = "webhook";
        settings = {
          url = "https://ntfy.lsck0.dev/${ntfyAlertTopic}?${ntfyQuery}";
          httpMethod = "POST";
          # ntfy denies anonymous publishing
          username = "grafana";
          password = config.sops.placeholder.ntfy-grafana-password;
        };
        disableResolveMessage = false;
      }];
    }] ++ lib.optional enableTelegram {
      orgId = 1;
      name = "telegram";
      receivers = [{
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
      }];
    };
  };

  # inverter solar api, polled per scrape
  froniusExporter = pkgs.writers.writePython3Bin "fronius-exporter" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/fronius-exporter.py);
  froniusListen = "127.0.0.1:9118";
  # local copy: a missing nas token must fail one scrape, not prometheus
  hassScrapeToken = "/run/prometheus-hass/token";

  # generated, so the json cannot drift from the queries in energy.py
  energyDashboard = pkgs.runCommand "energy.json" { } ''
    ${pkgs.python3}/bin/python3 ${../modules/dashboards/energy.py} $out
  '';

  spotPrice = pkgs.writers.writePython3Bin "spot-price" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ../scripts/spot-price.py);
in {
  networking.hostName = "vm-105";

  # bot token, chat id, ntfy password from sops
  sops.secrets = {
    ntfy-grafana-password = {};
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
    # home assistant's long-lived token, for its prometheus export
    // nasMount "/var/lib/homepage-tokens" "homepage-tokens";

  # every host uploads its journal here (base.nix); promtail forwards to loki
  # journal-remote ignores MaxUse for the received files, so they outgrew the disk
  systemd.services.journal-remote-vacuum = {
    description = "Cap received journals at 1G";
    startAt = "hourly";
    serviceConfig.Type = "oneshot";
    script = "${config.systemd.package}/bin/journalctl --directory=/var/log/journal/remote --vacuum-size=1G";
  };

  services.journald.remote = {
    enable = true;
    listen = "http";
    port = 19532;
    # loki is the long-term store, this is a buffer
    settings.Remote = { SplitMode = "host"; MaxUse = "1G"; };
  };

  # loki: logs from promtail on every vm
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = 3100;
      # tempo already holds grpc 9095
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

  # tempo: otlp tracing
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
    # nfs share leaks 0644, grafana warns
    "z /var/lib/grafana/data/grafana.db 0640 grafana grafana -"
  ];

  # localhost only, unauthenticated prober
  services.prometheus.exporters.blackbox = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9115;
    configFile = pkgs.writeText "blackbox.yml" (builtins.toJSON {
      modules = {
        # liveness: 401/403/3xx/404 count as up, 5xx not
        http_up = {
          prober = "http";
          timeout = "10s";
          http = {
            valid_status_codes = [ 200 201 204 301 302 303 307 308 401 403 404 ];
            follow_redirects = false;
            preferred_ip_protocol = "ip4";
            # self-signed backends (scheme = "https")
            tls_config.insecure_skip_verify = true;
          };
        };
        tcp_up = {
          prober = "tcp";
          timeout = "5s";
          tcp.preferred_ip_protocol = "ip4";
        };
      };
    });
  };

  services.prometheus = {
    enable = true;
    # energy history is the long-lived data; ~1GB a month on the nas
    retentionTime = "10y";
    extraFlags = [ "--storage.tsdb.retention.size=200GB" ];
    scrapeConfigs = [
      {
        # standard blackbox relabel
        job_name = "blackbox-http";
        metrics_path = "/probe";
        params.module = [ "http_up" ];
        scrape_interval = "60s";
        static_configs = map (p: {
          targets = [ p.url ];
          labels.service = p.name;
        }) probes;
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ];
      }
      {
        # sccache speaks redis, not http
        job_name = "blackbox-tcp";
        metrics_path = "/probe";
        params.module = [ "tcp_up" ];
        scrape_interval = "60s";
        static_configs = [{
          targets = [ "10.100.0.110:6379" ];
          labels.service = "sccache";
        }];
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9115"; }
        ];
      }
      {
        job_name = "homelab-node-exporter";
        relabel_configs = vmRelabels;
        static_configs = [{
          # the inventory, not a sweep of both /24s: 480 dead targets a minute bought nothing
          targets =
            lib.mapAttrsToList (_: v: "${v.ip}:9100") (lib.filterAttrs (_: v: v.type != "router") inventory)
            ++ lib.optional (router != null) "10.100.0.1:9100"
            ++ [ "192.168.178.200:9100" ];
        }];
      }
      {
        # traefik metrics (:8082) on both ingresses
        job_name = "traefik";
        static_configs = [{
          targets = [ "10.100.0.100:8082" "10.200.0.200:8082" ];
        }];
      }
      {
        # house power: pv, grid meter, battery
        job_name = "fronius";
        scrape_interval = "10s";
        static_configs = [{ targets = [ froniusListen ]; }];
      }
      {
        # gas and water readings typed in by hand
        job_name = "homeassistant";
        scrape_interval = "60s";
        metrics_path = "/api/prometheus";
        authorization.credentials_file = hassScrapeToken;
        static_configs = [{ targets = [ "10.100.0.125:80" ]; }];
      }
    ];
    # the hass token file only exists at runtime
    checkConfig = "syntax-only";
    # grafana unified alerting owns every rule
  };

  systemd.services.prometheus-hass-token = {
    description = "Stage the Home Assistant token for the Prometheus scrape";
    before = [ "prometheus.service" ];
    requiredBy = [ "prometheus.service" ];
    after = [ "remote-fs.target" ];
    path = [ pkgs.coreutils ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      install -d -m 750 -o prometheus -g prometheus ${builtins.dirOf hassScrapeToken}
      # empty token: the scrape answers 401 until the file shows up
      install -m 400 -o prometheus -g prometheus \
        "$(test -s /var/lib/homepage-tokens/hass-key.token && echo /var/lib/homepage-tokens/hass-key.token || echo /dev/null)" \
        ${hassScrapeToken}
    '';
  };

  # nfs state stops slowly, 45s default killed them
  systemd.services.prometheus.serviceConfig = {
    TimeoutStopSec = "5min";
    # upstream sets Restart already, so override
    Restart = lib.mkForce "on-failure";
    RestartSec = 10;
  };
  systemd.services.grafana.serviceConfig = {
    TimeoutStopSec = "2min";
    Restart = lib.mkForce "on-failure";
    RestartSec = 10;
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 80;
        root_url = "https://grafana.lsck0.dev";
      };
      # gated by authelia forwardauth
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
        # single-user lab: authelia users are admin
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
      # alerting always on, delivers to ntfy
      alerting = {
        # rendered by sops with secrets filled
        contactPoints.path = config.sops.templates."grafana-contact-points.yaml".path;
        policies.settings = {
          apiVersion = 1;
          # one message per category, re-sent at most daily while it lasts
          policies = [{
            orgId = 1;
            receiver = "ntfy";
            group_by = [ "alertname" ];
            group_wait = "1m";
            group_interval = "15m";
            repeat_interval = "24h";
            routes = lib.optional enableTelegram {
              receiver = "telegram";
              object_matchers = [ [ "notify" "=" "telegram" ] ];
            };
          }];
        };
        rules.settings = {
          apiVersion = 1;
          groups = [{
            orgId = 1;
            name = "homelab";
            folder = "Homelab";
            interval = "1m";
            rules = map mkRule [
              # offline
              {
                uid = "instance_down";
                title = "Guest offline";
                expr = instanceDownExpr;
                op = "lt"; threshold = 1;
                firing = "Offline"; resolved = "Back online";
                summary = "{{ $labels.vm }}";
                description = "node-exporter has been unreachable for 5 minutes. Check `vm status <id>` and the guest's journal.";
              }
              {
                uid = "service_down";
                title = "Service not answering";
                expr = "probe_success";
                op = "lt"; threshold = 1;
                for = "10m";
                firing = "Service down"; resolved = "Service back";
                summary = "{{ $labels.service }}";
                description = "The blackbox probe of the service's own port has failed for 10 minutes while its guest is up.";
              }
              # no backups taken
              {
                uid = "backup_stale";
                title = "NAS snapshot stale";
                expr = "time() - max(homelab_backup_last_success_timestamp_seconds{type=\"daily\"})";
                threshold = 26 * 3600;
                for = "0m";
                noData = "Alerting";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "NAS snapshot: none in over 26h";
                description = "Kopia on vm-109 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server`.";
              }
              {
                uid = "offsite_stale";
                title = "Off-site copy stale";
                expr = "time() - max(homelab_offsite_last_success_timestamp_seconds)";
                threshold = 26 * 3600;
                for = "0m";
                noData = "Alerting";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "Off-site (Proton Drive): no upload in over 26h";
                description = "proton-sync on vm-109 has not finished. Check `journalctl -u proton-sync`.";
              }
              {
                uid = "db_dump_stale";
                title = "Database dump stale";
                expr = "time() - max by (vm, db) (homelab_db_dump_last_success_timestamp_seconds)";
                threshold = 26 * 3600;
                for = "0m";
                firing = "Backups missing"; resolved = "Backups running again";
                summary = "{{ $labels.db }} dump on {{ $labels.vm }}: none in over 26h";
                description = "The nightly db-backup-<name> unit on that guest failed; the snapshot then holds only a live copy.";
              }
              # attacks
              {
                uid = "attack_flood";
                title = "Traffic flood";
                # crowdsec blocks background scans all day (tens/hour); only a real flood, orders of
                # magnitude over baseline, is worth waking for. sustained, so a brief spike is ignored.
                expr = "sum(rate(traefik_entrypoint_requests_total{entrypoint=\"websecure\"}[5m]))";
                threshold = 50;
                for = "15m";
                severity = "warning";
                firing = "Traffic flood"; resolved = "Flood over";
                summary = "{{ $values.A.Value | printf \"%.0f\" }} req/s sustained 15m: possible DoS";
                description = "Requests are far above baseline for 15 minutes. CrowdSec blocks known-bad; check `cscli metrics` and top talkers on vm-200. Routine scans do not trigger this.";
              }
              {
                uid = "sso_bruteforce";
                title = "Failed SSO logins";
                datasource = "loki";
                range = 900;
                # one failed login a week is normal
                expr = "sum(count_over_time({unit=\"authelia-main.service\"} |= \"Unsuccessful 1FA\" [15m]))";
                threshold = 4;
                for = "0m";
                severity = "warning";
                firing = "Attack detected"; resolved = "Attack over";
                summary = "{{ $values.A.Value }} failed SSO logins in 15 minutes";
                description = "Authelia rejected these passwords; it bans a user after 3 tries in 2 minutes.";
              }
              # not urgent, ntfy only
              {
                uid = "disk_full";
                title = "Disk almost full";
                expr = "100 * (1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"})";
                threshold = 90;
                for = "30m";
                severity = "warning";
                telegram = false;
                firing = "Disk almost full"; resolved = "Disk space ok";
                summary = "{{ $labels.vm }}: {{ printf \"%.0f\" $values.A.Value }}% used";
                description = "The guest's root filesystem is over 90%. Old generations, journal or images usually.";
              }
            ];
          }];
        };
      };
    };
  };

  # one board: map, http, system, logs
  environment.etc."grafana-dashboards/homelab.json".source = ../modules/dashboards/homelab.json;
  # house power, gas and water
  environment.etc."grafana-dashboards/energy.json".source = energyDashboard;

  # file provider rescans only at startup
  systemd.services.grafana.restartTriggers = [ ../modules/dashboards/homelab.json energyDashboard ];

  # wholesale price beside the contract price, for the cost panels
  systemd.services.spot-price = {
    description = "Export the day-ahead spot price";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = "${spotPrice}/bin/spot-price /var/lib/node-exporter-textfile/spot_price.prom";
  };

  # quarter-hour slots
  systemd.timers.spot-price = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "*:00/15:05"; Persistent = true; };
  };

  systemd.services.fronius-exporter = {
    description = "Prometheus exporter for the Fronius inverter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    environment = {
      FRONIUS_HOST = "192.168.178.46";
      FRONIUS_LISTEN = froniusListen;
    };
    serviceConfig = {
      ExecStart = "${froniusExporter}/bin/fronius-exporter";
      DynamicUser = true;
      Restart = "always";
      RestartSec = 10;
    };
  };

  # firing grafana alerts as a gauge, for readers that may not reach grafana (the desktop bar);
  # value is the start time, fingerprint keeps two alerts with equal labels apart
  systemd.services.grafana-alerts-export = {
    description = "Export firing Grafana alerts to Prometheus";
    after = [ "grafana.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      d=/var/lib/node-exporter-textfile
      out=$d/grafana_alerts.prom
      # no answer means no data, never a stale alert list
      if ! json=$(curl -sf -m10 -H 'Remote-User: admin' \
          'http://127.0.0.1:80/api/alertmanager/grafana/api/v2/alerts?active=true&silenced=false&inhibited=false'); then
        rm -f "$out"; exit 0
      fi
      {
        echo "# HELP homelab_alert_firing Start time of a firing Grafana alert."
        echo "# TYPE homelab_alert_firing gauge"
        echo "$json" | jq -r '
          def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
          .[] | "homelab_alert_firing{alertname=\"\(.labels.alertname // "alert" | esc)\",target=\"\(.labels.vm // .labels.instance // "" | esc)\",severity=\"\(.labels.severity // "" | esc)\",summary=\"\(.annotations.summary // "" | esc)\",fingerprint=\"\(.fingerprint | esc)\"} \(.startsAt | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch now | floor)"'
      } > "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
  systemd.timers.grafana-alerts-export = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2m"; OnUnitActiveSec = "30s"; };
  };

  # 3100 loki, 3200 tempo, 4317/4318 otlp, 19532 journal-remote
  networking.firewall.allowedTCPPorts = [ 80 9090 3100 3200 4317 4318 19532 ];

  # grafana trusts Remote-User (auth.proxy)
  homelab.ingressOnly.ports = [ 80 9090 3200 ];
  # desktop status widget scrapes prometheus
  homelab.ingressOnly.portSources."9090" = [ "192.168.178.0/24" "10.100.0.104/32" ];


  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;

  # consistent copy for the snapshot, the live file may be mid-write
  homelab.dbBackup.databases.grafana.sqlite = "/var/lib/grafana/data/grafana.db";
}
