{ config, lib, pkgs, nasMount, ... }:
let
  subnetTargets = subnet:
    builtins.map (host: "${subnet}.${toString host}:9100") (lib.range 1 254);

  # Telegram alerting. Grafana validates the contact point at startup and
  # crashes if the bot token is empty, and Nix cannot read the sops value at
  # build time — so this stays off until the token exists. To enable:
  #   1. sops src/secrets.json  → fill telegram-bot-token and telegram-chat-id
  #   2. flip this to true and redeploy
  enableTelegram = false;

  # ntfy topic for alerts — public but unguessable. Subscribe the phone to
  # https://ntfy.lsck0.dev/<this>. Change it to rotate.
  ntfyAlertTopic = "lsck0-homelab-a7f3k9d2xq";
in {
  networking.hostName = "vm-103";

  # Bot token + chat id come from sops via an env file Grafana reads; the
  # contact point references them with $__env{...} so the secret never lands in
  # the world-readable Nix store.
  sops.secrets = lib.mkIf enableTelegram {
    telegram-bot-token = {};
    telegram-chat-id = {};
  };
  sops.templates = lib.mkIf enableTelegram {
    "grafana-telegram.env".content = ''
      TELEGRAM_BOT_TOKEN=${config.sops.placeholder.telegram-bot-token}
      TELEGRAM_CHAT_ID=${config.sops.placeholder.telegram-chat-id}
    '';
  };
  systemd.services.grafana.serviceConfig.EnvironmentFile =
    lib.mkIf enableTelegram config.sops.templates."grafana-telegram.env".path;

  fileSystems = nasMount "/var/lib/grafana" "grafana"
    // nasMount "/var/lib/prometheus2" "prometheus"
    // nasMount "/var/lib/loki" "loki";

  # ── Loki: log aggregation for all VMs (promtail in base.nix pushes here) ────
  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      server.http_listen_port = 3100;
      # Tempo also runs on this VM and defaults its gRPC to 9095; move Loki's
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

  # ── Tempo: distributed tracing (OTLP), for services that emit spans ─────────
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
        static_configs = [{
          targets =
            (subnetTargets "10.100.0")
            ++ (subnetTargets "10.200.0")
            ++ [
              "192.168.178.200:9100"
            ];
        }];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 80;
        root_url = "https://grafana.lsck0.dev";
      };
      # Access is gated by Authelia ForwardAuth on the Traefik route, which
      # injects the Remote-User header. Grafana trusts that header (auth.proxy)
      # instead of granting every anonymous visitor admin — so hitting
      # 10.100.0.103:80 directly, without the header, gets nothing.
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
        # Single-user lab: anyone Authelia lets through is the admin.
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
      # Alerting is always on and delivers to ntfy (vm-206, public, works when
      # the LAN is down) with no credentials needed — subscribe the phone app to
      # https://ntfy.lsck0.dev/${ntfyAlertTopic}. Telegram is added as a second
      # channel once its token is filled (enableTelegram).
      alerting = {
        contactPoints.settings = {
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
                bottoken = "$__env{TELEGRAM_BOT_TOKEN}";
                chatid = "$__env{TELEGRAM_CHAT_ID}";
              };
              disableResolveMessage = false;
            };
          }];
        };
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
                    # Only real VMs: currently down AND up at some point in the
                    # last 6h. Prometheus statically scrapes the whole /24, so
                    # without this the rule fires for ~480 phantom IPs.
                    expr = "up{job=\"homelab-node-exporter\"} == 0 and max_over_time(up{job=\"homelab-node-exporter\"}[6h]) > 0";
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
                    # A returns 1 for a real, currently-down target; fire on that.
                    conditions = [{
                      evaluator = { type = "gt"; params = [ 0 ]; };
                    }];
                  };
                }
              ];
              for = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.instance }} node-exporter is down";
            }
            {
              uid = "backup_stale";
              title = "NAS backup stale (dead-man)";
              condition = "C";
              # No successful daily backup for > 26h. no_data also fires, so a
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

  environment.etc = {
    "grafana-dashboards/node-exporter.json" = {
      source = ./dashboards/node-exporter.json;
    };
    "grafana-dashboards/homelab-overview.json" = {
      source = ./dashboards/homelab-overview.json;
    };
  };

  # 3100 Loki push, 3200 Tempo, 4317/4318 OTLP trace ingest.
  networking.firewall.allowedTCPPorts = [ 80 9090 3100 3200 4317 4318 ];
}
