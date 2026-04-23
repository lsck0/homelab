{ nasMount, ... }: {
  networking.hostName = "vm-109";

  fileSystems = nasMount "/var/lib/registry" "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2";
    ports = [ "5000:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
    environment = {
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Origin = "[\"*\"]";
      REGISTRY_HTTP_HEADERS_Access-Control-Allow-Methods = "[\"HEAD\", \"GET\", \"OPTIONS\", \"DELETE\"]";
    };
  };

  virtualisation.oci-containers.containers.registry-ui = {
    image = "joxit/docker-registry-ui:latest";
    ports = [ "80:80" ];
    environment = {
      REGISTRY_TITLE = "Homelab Registry";
      SINGLE_REGISTRY = "true";
      DELETE_IMAGES = "true";
      NGINX_PROXY_PASS_URL = "http://10.100.0.109:5000";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5000 ];
}
