# observability: prometheus, loki, tempo, pyroscope, grafana and the alerting
{
  net,
  telemetry,
  profiles,
  ...
}:
{
  roles = [ "collector" ];

  vm = {
    bootPhase = "network";
    needs = [ "nfs" ];
    # prometheus, loki, grafana: 1331 MiB peak, 1024 at p95 over 35d
    memoryMiB = 1536;
    # the stores on local disk (main.nix sizes prometheus' retention from it: 56GB), journal-remote's 1G, the system
    diskGiB = 80;
  };

  grants = [
    {
      from = [
        "dashboard"
        "114"
        "operator"
      ];
      tcp = [ telemetry.ports.prometheus ];
      why = "the dashboard's widgets, the terminal's feeds and hermes read the query api";
    }
    # the house lan does not: the readings would tell anyone on it when the house is occupied
    {
      from = [
        "workstation"
        "notebook"
        "wireguard"
      ];
      tcp = with telemetry.ports; [
        prometheus
        loki
      ];
      why = "the desktop bar's homelab widget reads both query apis (lab.json monitoring), at home and on the road";
    }
    {
      from = [
        "114"
        "operator"
      ];
      tcp = [ telemetry.ports.loki ];
      why = "stats-sync and hermes read logs";
    }
    {
      from = [ net.zones.external.ingress ];
      tcp = [ telemetry.ports.otlpFrontend ];
      why = "the edge relays the browsers' frontend telemetry";
    }
  ];

  services = {
    grafana = {
      port = telemetry.ports.grafana;
      homepage = {
        group = "Core";
        icon = "grafana";
        # main.nix grafana-alerts-export: the firing alerts, the watchdog left out
        widget = {
          type = "prometheusmetric";
          url = telemetry.urls.prometheus;
          settings.metrics = [
            {
              label = "Alerts firing";
              query = "count(homelab_alert_firing) or vector(0)";
            }
            {
              label = "Targets down";
              query = "count(up{idle=\"\"} == 0) or vector(0)";
            }
          ];
        };
      };
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    };
  };

  # main.nix spot-price: written every quarter hour, 0 while energy-charts has no price for now
  alerts.spot_price_unavailable = {
    title = "Spot price unavailable";
    category = "service";
    expr = "max_over_time(energy_spot_price_available[2h])";
    op = "lt";
    threshold = 1;
    for = "0m";
    summary = "energy-charts unavailable: no day-ahead price for 2 hours";
    description = "The price cache ran out and energy-charts.info does not answer; the cost panels show no spot price meanwhile. spot-price asks again every hour and this resolves by itself. `journalctl -u spot-price` on vm-103.";
  };

  tokenReads = [ "hass-key" ];

  shares = {
    "data/app-dashboards".readOnly = true;
    "data/grafana".localState = true;
    "data/loki".localState = true;
    "data/prometheus".localState = true;
    "data/pyroscope".localState = true;
  };
}
