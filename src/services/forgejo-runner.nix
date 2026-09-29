# forgejo actions runner; the host mounts /var/lib/homepage-tokens
{ config, pkgs, nasMount, retry, ... }: {
  fileSystems = nasMount "/var/lib/forgejo-runner" "forgejo-runner";

  # job containers; the host sets virtualisation.oci-containers.backend = "docker"
  virtualisation.docker.enable = true;
  # job images pile up with every ci run
  virtualisation.docker.autoPrune = { enable = true; dates = "weekly"; flags = [ "--all" "--filter" "until=168h" ]; };

  virtualisation.oci-containers.containers.forgejo-runner = {
    image = "code.forgejo.org/forgejo/runner:6.2.1";
    cmd = [ "forgejo-runner" "daemon" "--config" "/data/config.yaml" ];
    volumes = [
      "/var/lib/forgejo-runner:/data"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];
    user = "root:root";
    extraOptions = [
      "--add-host=git.lsck0.dev:10.100.0.100"
      "--add-host=registry.lsck0.dev:10.100.0.118"
      "--add-host=sccache.lsck0.dev:10.100.0.110"
    ];
    environment = {
      SCCACHE_REDIS = "redis://sccache.lsck0.dev";
    };
  };

  # register with the token forgejo exports to the nas
  systemd.services.forgejo-runner-register = {
    description = "Register Forgejo runner";
    before = [ "docker-forgejo-runner.service" ];
    requiredBy = [ "docker-forgejo-runner.service" ];
    path = [ pkgs.curl pkgs.jq pkgs.docker pkgs.gnused ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # default config if missing
      if [ ! -f /var/lib/forgejo-runner/config.yaml ]; then
        docker run --rm -v /var/lib/forgejo-runner:/data \
          code.forgejo.org/forgejo/runner:6.2.1 \
          forgejo-runner generate-config > /var/lib/forgejo-runner/config.yaml
      fi

      # docker socket in job containers for build/push
      sed -i 's|docker_host: "-"|docker_host: "automount"|' /var/lib/forgejo-runner/config.yaml
      # internal hostnames in job containers
      sed -i '/^container:/,/^[^ ]/{s|^  options: .*|  options: "--add-host=git.lsck0.dev:10.100.0.100 --add-host=registry.lsck0.dev:10.100.0.118 --add-host=sccache.lsck0.dev:10.100.0.110"|}' \
        /var/lib/forgejo-runner/config.yaml

      # wait for the forgejo api
      ${retry} 90 2 curl -sf https://git.lsck0.dev/api/healthz

      # failed ping means a stale token, re-register
      if [ -f /var/lib/forgejo-runner/.runner ]; then
        if docker run --rm \
          -v /var/lib/forgejo-runner:/data \
          --add-host=git.lsck0.dev:10.100.0.100 \
          code.forgejo.org/forgejo/runner:6.2.1 \
          forgejo-runner ping --instance https://git.lsck0.dev >/dev/null 2>&1; then
          echo "Runner already registered and valid"
          exit 0
        fi
        echo "Runner ping failed: token likely stale, re-registering..."
        rm -f /var/lib/forgejo-runner/.runner
      fi

      # registration token from the nas
      TOKEN_FILE="/var/lib/homepage-tokens/forgejo-runner.token"
      ${retry} 30 5 test -s "$TOKEN_FILE" || { echo "runner token missing at $TOKEN_FILE: did forgejo-runner-token run?"; exit 1; }

      REG_TOKEN=$(cat "$TOKEN_FILE")

      # `docker` label image needs docker cli and node
      docker run --rm -v /var/lib/forgejo-runner:/data \
        --add-host=git.lsck0.dev:10.100.0.100 \
        code.forgejo.org/forgejo/runner:6.2.1 \
        forgejo-runner register \
          --instance https://git.lsck0.dev \
          --token "$REG_TOKEN" \
          --name ${config.networking.hostName}-runner \
          --labels "docker:docker://catthehacker/ubuntu:act-22.04,ubuntu-latest:docker://catthehacker/ubuntu:act-22.04,rust:docker://rust:1.80-bookworm" \
          --no-interactive

      echo "Runner registered successfully"
    '';
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo-runner 0750 1000 1000 -"
  ];

}
