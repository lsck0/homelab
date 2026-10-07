# observability: prometheus, loki, tempo, pyroscope, grafana and the alerting
{ telemetry, ... }: {
  roles = [ "collector" ];

  vm = {
    bootPhase = "network";
    needs = [ "nfs" ];
    # prometheus, loki, grafana: 1122 MiB peak over 7d
    memoryMiB = 2560;
    # explicit floor: tsdb head and loki chunks are working memory
    balloonMiB = 1536;
    # the stores on local disk (main.nix sizes prometheus' retention from it: 56GB), journal-remote's 1G, the system
    diskGiB = 80;
  };

  grants = [
    {
      from = [ "103" "104" "114" ];
      tcp = [ telemetry.ports.prometheus ];
      why = "the dashboard's widgets, the terminal's feeds and hermes read the query api";
    }
    # the house lan does not: the readings would tell anyone on it when the house is occupied
    {
      from = [ "workstation" "wireguard" ];
      tcp = [ telemetry.ports.prometheus ];
      why = "the desktop bar's homelab widget reads the query api (lab.json monitoring), at home and on the road";
    }
    { from = [ "104" "114" ]; tcp = [ telemetry.ports.loki ]; why = "stats-sync and hermes read logs"; }
    { from = [ "200" ]; tcp = [ telemetry.ports.otlpFrontend ]; why = "the edge relays the browsers' frontend telemetry"; }
  ];

  services = {
    grafana = {
      port = telemetry.ports.grafana;
      homepage = {
        group = "Core";
        icon = "grafana";
        widget = { type = "prometheus"; url = telemetry.urls.prometheus; };
      };
    };
  };

  # main.nix spot-price: written every quarter hour, 0 while energy-charts has no price for now
  alerts.spot_price_unavailable = {
    title = "Spot price unavailable";
    category = "service";
    expr = "max_over_time(energy_spot_price_available[2h])";
    op = "lt"; threshold = 1;
    for = "0m";
    summary = "energy-charts unavailable: no day-ahead price for 2 hours";
    description = "The price cache ran out and energy-charts.info does not answer; the cost panels show no spot price meanwhile. spot-price asks again every hour and this resolves by itself. `journalctl -u spot-price` on vm-105.";
  };

  tokenReads = [ "hass-key" ];

  shares = {
    "data/app-dashboards".readOnly = true;
    "data/grafana" = { };
    "data/loki" = { };
    "data/prometheus" = { };
    "data/pyroscope" = { };
  };
}
