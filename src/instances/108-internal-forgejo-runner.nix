{ pkgs, ... }: {
  networking.hostName = "vm-108";

  virtualisation.docker.enable = true;

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.forgejo-runner = {
    image = "code.forgejo.org/forgejo/runner:6.2.1";
    cmd = [ "forgejo-runner" "daemon" "--config" "/data/config.yaml" ];
    volumes = [
      "/var/lib/forgejo-runner:/data"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];
    user = "root:root";
    environment = {
      SCCACHE_REDIS = "redis://10.100.0.106:6379";
    };
  };

  # Register runner with Forgejo if not already registered
  systemd.services.forgejo-runner-register = {
    description = "Register Forgejo runner";
    before = [ "docker-forgejo-runner.service" ];
    requiredBy = [ "docker-forgejo-runner.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.docker ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # Skip if already registered
      if [ -f /var/lib/forgejo-runner/.runner ]; then
        echo "Runner already registered"
        exit 0
      fi

      # Generate default config if missing
      if [ ! -f /var/lib/forgejo-runner/config.yaml ]; then
        docker run --rm -v /var/lib/forgejo-runner:/data \
          code.forgejo.org/forgejo/runner:6.2.1 \
          generate-config > /var/lib/forgejo-runner/config.yaml
      fi

      # Wait for Forgejo API
      for i in $(seq 1 90); do
        if curl -sf http://10.100.0.107:80/api/v1/settings/api >/dev/null 2>&1; then break; fi
        sleep 2
      done

      # Get registration token via Forgejo API (needs admin token)
      # Use CLI inside Forgejo container on VM 105 — not available from here
      # Runner must be registered manually once:
      #   docker exec -it forgejo-runner forgejo-runner register \
      #     --instance http://10.100.0.107:80 \
      #     --token <TOKEN_FROM_FORGEJO_ADMIN> \
      #     --name vm-108-runner \
      #     --labels docker:docker://node:20-bookworm,ubuntu-latest:docker://ubuntu:22.04 \
      #     --no-interactive
      echo "Runner not registered. Get token from https://git.internal/-/admin/runners"
      echo "Then run: docker exec -it forgejo-runner forgejo-runner register --instance http://10.100.0.107:80 --token <TOKEN> --name vm-108-runner --labels docker:docker://node:20-bookworm,ubuntu-latest:docker://ubuntu:22.04 --no-interactive"
      exit 1
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo-runner 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [];
}
