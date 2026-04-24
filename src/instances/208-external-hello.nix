{ ... }: {
  networking.hostName = "vm-208";

  homelab.dockerStack = {
    enable = true;
    stackName = "hello";
    composeFile = ''
      services:
        hello:
          image: 10.100.0.109:5000/axum-webserver:latest
          ports:
            - "80:8000"
          restart: unless-stopped
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8000/"]
            interval: 30s
            timeout: 5s
            retries: 3
        watchtower:
          image: containrrr/watchtower
          volumes:
            - /var/run/docker.sock:/var/run/docker.sock
          command: --interval 300 --cleanup hello
          restart: unless-stopped
    '';
  };

  # Registry is HTTP-only on port 5000
  virtualisation.docker.daemon.settings.insecure-registries = [ "10.100.0.109:5000" ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
