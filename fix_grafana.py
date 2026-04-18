with open('src/instances/301-grafana.nix', 'r') as f:
    config = f.read()

# Fix syntax error in nix file from the simple replace
config = config.replace("""      dashboards.settings = {
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

  networking.firewall.allowedTCPPorts = [ 80 9090 ];
}""", """      };
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
}""")

with open('src/instances/301-grafana.nix', 'w') as f:
    f.write(config)
