{ ... }: {
  networking.hostName = "vm-208";

  homelab.dockerStack = {
    enable = true;
    stackName = "hello";
    composeFile = ''
      services:
        hello:
          image: registry.lsck0.dev/axum-webserver:latest
          ports:
            - "80:8000"
          restart: unless-stopped
          healthcheck:
            test: ["CMD", "curl", "-f", "http://localhost:8000/"]
            interval: 30s
            timeout: 5s
            retries: 3
    '';
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
