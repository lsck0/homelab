{ config, pkgs, lib, inventory, nasMount, ... }:
let


  # real vms only: down now, up within 6h
  onDemandIps = lib.mapAttrsToList (_: v: v.ip) (lib.filterAttrs (_: v: v.enabled == "onDemand") inventory);
  instanceDownExpr = "up{job=\"homelab-node-exporter\""
    + lib.optionalString (onDemandIps != []) ",instance!~\"(${lib.concatMapStringsSep "|" (ip: lib.replaceStrings [ "." ] [ "\\\\." ] ip) onDemandIps}):9100\""
    + "} == 0 and max_over_time(up{job=\"homelab-node-exporter\"}[6h]) > 0";
  subnetTargets = subnet:
    builtins.map (host: "${subnet}.${toString host}:9100") (lib.range 1 254);

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
    ++ lib.optionals (router != null) [ (vmLabel "10.100.0.1" "router") (vmLabel "10.200.0.1" "router") ]
    ++ [ (vmLabel "192.168.178.200" "proxmox") ];

  # ── blackbox probes ────────────────────────────────────────────────────────
  # probe backends, public names always 302 via authelia
  routes = import ../modules/routes.nix;
  probes =
    let
      # on-demand/disabled vms would alarm forever
      alwaysOn = r: (inventory.${toString r.vmid}.enabled or "false") == "true"
        && (r.monitor or true);
      ofSide = side: lib.mapAttrsToList (name: r: {
        inherit name;
        url = "${r.scheme or "http"}://${inventory.${toString r.vmid}.ip}:${toString r.port}";
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

  # compact html per alert, not grafana's wall
  telegramMessage = ''
    {{ if eq .Status "firing" }}🔴 <b>FIRING</b>{{ else }}✅ <b>RESOLVED</b>{{ end }} · <b>{{ .CommonLabels.alertname }}</b>
    {{ range .Alerts }}
    {{ if .Labels.vm }}<code>{{ .Labels.vm }}</code>{{ else if .Labels.instance }}<code>{{ .Labels.instance }}</code>{{ end }}{{ if .Labels.severity }} [{{ .Labels.severity }}]{{ end }}
    {{ if .Annotations.summary }}{{ .Annotations.summary }}{{ end }}
    {{ if .Annotations.description }}<i>{{ .Annotations.description }}</i>{{ end }}
    {{ end }}
    <a href="https://grafana.lsck0.dev/alerting/list">open Grafana</a>'';

  # single delivery path: Grafana unified alerting
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
          # ntfy denies anonymous publishing
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
    // nasMount "/var/lib/loki" "loki";

  # every host uploads its journal here (base.nix); promtail forwards to loki
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
    retentionTime = "30d";
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
          targets =
            (subnetTargets "10.100.0")
            ++ (subnetTargets "10.200.0")
            ++ [
              "192.168.178.200:9100"
            ];
        }];
      }
      {
        # traefik metrics (:8082) on both ingresses
        job_name = "traefik";
        static_configs = [{
          targets = [ "10.100.0.100:8082" "10.200.0.200:8082" ];
        }];
      }
    ];
    # grafana unified alerting owns every rule
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
              # node-exporter target unreachable for 5m
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
                    # `up == 0 and ...` keeps the value of `up`
                    conditions = [{
                      evaluator = { type = "lt"; params = [ 1 ]; };
                    }];
                  };
                }
              ];
              for = "5m";
              # empty result means nothing is down
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
              # no daily backup for > 26h, no_data fires too
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
              annotations.description = "Kopia on vm-109 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server` and https://backup.lsck0.dev.";
            }
            {
              uid = "service_down";
              title = "Service not answering";
              condition = "C";
              # vm up while the container crash-loops
              data = [
                {
                  refId = "A";
                  relativeTimeRange = { from = 600; to = 0; };
                  datasourceUid = "prometheus";
                  model = {
                    refId = "A";
                    expr = "probe_success";
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
                      evaluator = { type = "lt"; params = [ 1 ]; };
                    }];
                  };
                }
              ];
              for = "5m";
              # never-reported is a scrape problem
              noDataState = "OK";
              execErrState = "Error";
              labels.severity = "warning";
              annotations.summary = "{{ $labels.service }} is not answering on {{ $labels.instance }}";
              annotations.description = "The blackbox probe of this service's own port has failed for 5 minutes while its VM is still up. Check the unit and `podman ps` on that VM.";
            }
            {
              uid = "ossec_alert";
              title = "OSSEC alert on the hypervisor";
              condition = "C";
              # ossec level 7+, alert on the increase
              data = [
                {
                  refId = "A";
                  relativeTimeRange = { from = 3600; to = 0; };
                  datasourceUid = "prometheus";
                  model = {
                    refId = "A";
                    expr = "increase(homelab_ossec_alerts_high[1h])";
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
                      evaluator = { type = "gt"; params = [ 0 ]; };
                    }];
                  };
                }
              ];
              for = "0m";
              # absent until ossec is installed
              noDataState = "OK";
              execErrState = "Error";
              labels.severity = "critical";
              annotations.summary = "OSSEC raised {{ $value }} level 7+ alerts on the hypervisor";
              annotations.description = "File integrity or rootcheck findings on 192.168.178.200. Read them with `tail -50 /var/ossec/logs/alerts/alerts.log`.";
            }];
          }];
        };
      };
    };
  };

  # one board: map, http, system, logs
  environment.etc."grafana-dashboards/homelab.json".source = ../modules/dashboards/homelab.json;

  # file provider rescans only at startup
  systemd.services.grafana.restartTriggers = [ ../modules/dashboards/homelab.json ];

  # 3100 loki, 3200 tempo, 4317/4318 otlp, 19532 journal-remote
  networking.firewall.allowedTCPPorts = [ 80 9090 3100 3200 4317 4318 19532 ];

  # grafana trusts Remote-User (auth.proxy)
  homelab.ingressOnly.ports = [ 80 9090 3200 ];
  # desktop status widget scrapes prometheus
  homelab.ingressOnly.portSources."9090" = [ "192.168.178.0/24" "10.100.0.104/32" ];


  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
