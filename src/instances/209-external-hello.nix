{ config, ... }:
let
  # an unprivileged lxc may not program ipvs, so no routing mesh or vip there:
  # publish on the host and stop the old task first, a few seconds of downtime per deploy
  meshless = config.boot.isContainer;
  order = if meshless then "stop-first" else "start-first";

  # vm: zero-downtime, the new task must be healthy first
  webService = image: publishedPort: ''
    image: ${image}
    ports:
      - target: 8000
        published: ${toString publishedPort}
        protocol: tcp
        mode: ${if meshless then "host" else "ingress"}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
    deploy:
      replicas: 1
      endpoint_mode: ${if meshless then "dnsrr" else "vip"}
      update_config:
        parallelism: 1
        order: ${order}
        failure_action: rollback
      rollback_config:
        order: ${order}
      restart_policy:
        condition: any
  '';
  indent = s: builtins.replaceStrings [ "\n" ] [ "\n    " ] s;
in {
  networking.hostName = "vm-209";

  # ci/cd target
  homelab.swarm = {
    enable = true;
    updateInterval = "1m";

    stacks = {
      hello = ''
        services:
          web:
            ${indent (webService "registry.lsck0.dev/hello:latest" 80)}
      '';
    };

    # private images: add a registries."ghcr.io" entry
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
