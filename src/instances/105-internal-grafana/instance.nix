# observability: prometheus, loki, tempo, grafana
{ telemetry, ... }: {
  vm = {
    bootPhase = "network";
    needs = [ "nfs" ];
    # prometheus, loki, grafana: 1122 MiB peak over 7d
    memoryMiB = 2560;
    # explicit floor: tsdb head and loki chunks are working memory
    balloonMiB = 1536;
    # remote journal buffer (1G) plus local grafana state
    diskGiB = 16;
  };

  grants = [
    {
      from = [ "103" "114" ];
      tcp = [ telemetry.ports.prometheus ];
      why = "the dashboard's widgets and hermes read the query api";
    }
    { from = [ "114" ]; tcp = [ telemetry.ports.loki ]; why = "hermes reads logs"; }
  ];

  services = {
    grafana = {
      port = 80;
      homepage = {
        group = "Core";
        icon = "grafana";
        widget = { type = "prometheus"; url = "http://10.100.0.105:9090"; };
      };
    };
  };
}
