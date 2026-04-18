{ pkgs, ... }: {
  networking.hostName = "vm-106";

  virtualisation.docker.enable = true;

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.forgejo-runner = {
    image = "codeberg.org/forgejo/runner:6";
    volumes = [
      "/var/lib/forgejo-runner:/data"
      "/var/run/docker.sock:/var/run/docker.sock"
    ];
    environment = {
      FORGEJO_URL = "http://10.100.0.105:80";
      SCCACHE_REDIS = "redis://10.100.0.107:6379";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/forgejo-runner 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [];
}
