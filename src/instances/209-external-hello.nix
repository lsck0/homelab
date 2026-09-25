{ ... }:
let
  # zero-downtime rollout: the new task must pass its healthcheck before the old one
  webService = image: publishedPort: ''
    image: ${image}
    ports:
      - "${toString publishedPort}:8000"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s
    deploy:
      replicas: 1
      update_config:
        parallelism: 1
        order: start-first
        failure_action: rollback
      rollback_config:
        order: start-first
      restart_policy:
        condition: any
  '';
  indent = s: builtins.replaceStrings [ "\n" ] [ "\n    " ] s;
in {
  networking.hostName = "vm-209";

  # CI/CD target.
  homelab.swarm = {
    enable = true;
    updateInterval = "1m";

    stacks = {
      hello = ''
        services:
          web:
            ${indent (webService "registry.lsck0.dev/hello:latest" 80)}
      '';
      hello-gh = ''
        services:
          web:
            ${indent (webService "ghcr.io/lsck0/hello:latest" 8080)}
      '';
    };

    # private image example (token in sops): registries."ghcr.io" =
  };

  networking.firewall.allowedTCPPorts = [ 80 8080 ];
}
