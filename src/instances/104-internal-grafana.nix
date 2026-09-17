{ config, lib, pkgs, inventory, nasMount, ... }:
let
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

  # alert delivery: ntfy always, the Hermes Telegram bot with enableTelegram.
  contactPoints = {
    apiVersion = 1;
    contactPoints = [{
      orgId = 1;
      name = "homelab-alerts";
      receivers = [{
        uid = "ntfy_cp";
        type = "webhook";
        settings = {
          url = "https://ntfy.lsck0.dev/${ntfyAlertTopic}";
          httpMethod = "POST";
        };
        disableResolveMessage = false;
      }] ++ lib.optional enableTelegram {
        uid = "telegram_cp";
        type = "telegram";
        settings = {
          bottoken = config.sops.placeholder.telegram-bot-token;
          chatid = config.sops.placeholder.telegram-chat-id;
        };
        disableResolveMessage = false;
      };
    }];
  };

  # ntfy topic for alerts: public but unguessable. Subscribe the phone to
  # https://ntfy.lsck0.dev/<this>. Change it to rotate.
  ntfyAlertTopic = "lsck0-homelab-a7f3k9d2xq";
in {
  networking.hostName = "vm-104";

  # bot token + chat id come from sops: rendered into Grafana's contact point
  # file and Alertmanager's environment at activation, never into the Nix store.
  sops.secrets = lib.mkIf enableTelegram {
    telegram-bot-token = {};
    telegram-chat-id = {};
  };
  sops.templates = lib.mkIf enableTelegram {
    "grafana-contact-points.yaml" = {
      owner = "grafana";
      content = builtins.toJSON contactPoints;
    };
    "alertmanager-telegram.env".content = ''
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
      TELEGRAM_CHAT_ID=${config.sops.placeholder.telegram-chat-id}
    '';
  };

  fileSystems = nasMount "/var/lib/grafana" "grafana"
    // nasMount "/var/lib/prometheus2" "prometheus"
    // nasMount "/var/lib/loki" "loki";

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
    # Prometheus-native alerting path (in addition to Grafana unified alerting).
    alertmanagers = [{ static_configs = [{ targets = [ "127.0.0.1:9093" ]; }]; }];
    rules = [ (builtins.toJSON {
      groups = [{
        name = "homelab";
        rules = [{
          alert = "InstanceDown";
          expr = instanceDownExpr;
          for = "5m";
          labels.severity = "critical";
          annotations.summary = "{{ $labels.instance }} is down";
        }];
      }];
    }) ];
  };

  # Alertmanager: routes Prometheus alerts to ntfy (vm-203, public) and, with
  # enableTelegram, to the Hermes bot. configText (not `configuration`) because
  # chat_id must stay an unquoted integer after envsubst fills in the secrets.
  services.prometheus.alertmanager = {
    enable = true;
    port = 9093;
    # the file only becomes valid after envsubst at start.
    checkConfig = !enableTelegram;
    environmentFile = lib.mkIf enableTelegram config.sops.templates."alertmanager-telegram.env".path;
    configText = lib.concatStringsSep "\n" ([
      "route:"
      "  receiver: homelab"
      "  group_by: [alertname]"
      "  group_wait: 30s"
      "  group_interval: 5m"
      "  repeat_interval: 4h"
      "receivers:"
      "  - name: homelab"
      "    webhook_configs:"
      "      - url: https://ntfy.lsck0.dev/${ntfyAlertTopic}"
    ] ++ lib.optionals enableTelegram [
      "    telegram_configs:"
      "      - bot_token: $TELEGRAM_BOT_TOKEN"
      "        chat_id: $TELEGRAM_CHAT_ID"
      "        send_resolved: true"
    ]) + "\n";
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
      # alerting is always on and delivers to ntfy (vm-203, public, works when
      # the LAN is down) with no credentials needed: subscribe the phone app to
      # https://ntfy.lsck0.dev/${ntfyAlertTopic}. Telegram is added as a second
      # channel once its token is filled (enableTelegram).
      alerting = {
        # rendered by sops at activation with the secrets filled in. Not via
        # $__env{}: Grafana re-parses substituted values, turning the numeric
        # Telegram chat id into a number, and then refuses to start.
        contactPoints.path = if enableTelegram
          then config.sops.templates."grafana-contact-points.yaml".path
          else pkgs.writeText "contact-points.yaml" (builtins.toJSON contactPoints);
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
              annotations.summary = "{{ $labels.instance }} node-exporter is down";
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

  # 3100 Loki push, 3200 Tempo, 4317/4318 OTLP trace ingest, 9093 Alertmanager.
  networking.firewall.allowedTCPPorts = [ 80 9090 3100 3200 4317 4318 9093 ];
}
