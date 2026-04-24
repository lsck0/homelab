{ ... }: {
  networking.hostName = "vm-208";

  homelab.dockerStack = {
    enable = true;
    stackName = "hello";
    useSwarm = true;
    updateInterval = "5m";
    composeFile = ''
      services:
        hello:
          image: 10.100.0.109:5000/axum-webserver:latest
          ports:
            - "80:8000"
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8000/"]
            interval: 30s
            timeout: 5s
            retries: 3
          deploy:
            update_config:
              parallelism: 1
              order: start-first
            restart_policy:
              condition: any
    '';
  };

  # Registry is HTTP-only on port 5000
  virtualisation.docker.daemon.settings.insecure-registries = [ "10.100.0.109:5000" ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
