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

  tokenReads = [ "hass-key" ];

  shares = {
    "data/app-dashboards".readOnly = true;
    "data/grafana" = { };
    "data/loki" = { };
    "data/prometheus" = { };
    "data/pyroscope" = { };
  };
}
