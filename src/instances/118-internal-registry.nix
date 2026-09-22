{ nasMount, ... }: {
  networking.hostName = "vm-118";

  fileSystems = nasMount "/var/lib/registry" "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2.8.3";
    ports = [ "5000:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
    environment = {
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin = "[\"*\"]";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods = "[\"HEAD\", \"GET\", \"OPTIONS\", \"DELETE\"]";
    };
  };

  virtualisation.oci-containers.containers.registry-ui = {
    image = "joxit/docker-registry-ui:2.6.0";
    ports = [ "80:80" ];
    environment = {
      REGISTRY_TITLE = "Homelab Registry";
      SINGLE_REGISTRY = "true";
      DELETE_IMAGES = "true";
      NGINX_PROXY_PASS_URL = "http://10.100.0.118:5000";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5000 ];

  # the registry has no authentication and the UI has no login: only the
  # ingress, the CI runners and the swarm host that pulls the images may reach
  # it. The external Traefik additionally denies registry.lsck0.dev publicly.
  homelab.ingressOnly = {
    ports = [ 80 5000 ];
    extraSources = [
      "10.100.0.116/32"   # Forgejo CI runner
      "10.100.0.117/32"   # GitHub CI runners
      "10.100.0.118/32"   # registry-ui -> registry
      "10.200.0.209/32"   # Docker Swarm host that pulls the images
    ];
  };
}
