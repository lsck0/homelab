{ ... }: {
  networking.hostName = "vm-104";

  virtualisation.oci-containers.containers.forgejo-runner = {
    image = "codeberg.org/forgejo/runner:6";
    ports = [];
    volumes = [
      "/var/lib/forgejo-runner:/data"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];
    environment = {
      FORGEJO_URL = "http://10.100.0.103:80";
      SCCACHE_REDIS = "redis://10.100.0.105:6379";
    };
  };

  networking.firewall.allowedTCPPorts = [];
}