{ lib, ... }:
let
  subnetTargets = subnet:
    builtins.map (host: "${subnet}.${toString host}:9100") (lib.range 1 254);
in {
  networking.hostName = "luca-grafana";

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
              "127.0.0.1:9100"
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
      };
      auth = {
        disable_login_form = true;
      };
      "auth.anonymous" = {
        enabled = true;
        org_role = "Admin";
      };
      users = {
        allow_sign_up = false;
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
            isDefault = true;
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
    };
  };

  environment.etc = {
    "grafana-dashboards/node-exporter.json" = {
      source = ./dashboards/node-exporter.json;
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 9090 ];
}
