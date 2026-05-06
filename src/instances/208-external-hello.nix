{ pkgs, ... }: {
  networking.hostName = "vm-208";

  # Initialize Docker Swarm single-node before any stack deploys
  systemd.services.docker-swarm-init = {
    description = "Initialize Docker Swarm single-node manager";
    after = [ "docker.service" ];
    before = [ "docker-stack-hello.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.docker ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      docker info --format '{{.Swarm.LocalNodeState}}' | grep -q active && exit 0
      docker swarm init --advertise-addr 127.0.0.1
    '';
  };

  homelab.dockerStack = {
    enable = true;
    stackName = "hello";
    useSwarm = true;
    updateInterval = "5m";
    composeFile = ''
      services:
        hello:
          image: registry.lsck0.dev/hello:latest
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

  networking.firewall.allowedTCPPorts = [ 80 ];
}
