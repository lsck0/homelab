{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-118";

  fileSystems = nasMount "/var/lib/registry" "registry";

  virtualisation.oci-containers.containers.registry = {
    image = "registry:2.8.3";
    ports = [ "5000:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
    environment = {
      # without this the registry 405s on DELETE, so the ui delete button fails
      REGISTRY_STORAGE_DELETE_ENABLED = "true";
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

  # ui deletes only drop the manifest; reclaim blob space by gc-ing offline (registry
  # stopped so a concurrent push cannot lose blobs). --delete-untagged clears orphaned manifests.
  systemd.services.registry-gc = {
    description = "Reclaim deleted registry blobs";
    path = [ pkgs.podman pkgs.systemd ];
    serviceConfig.Type = "oneshot";
    script = ''
      systemctl stop podman-registry
      podman run --rm -v /var/lib/registry:/var/lib/registry registry:2.8.3 \
        garbage-collect --delete-untagged /etc/docker/registry/config.yml || true
      systemctl start podman-registry
    '';
  };
  systemd.timers.registry-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "03:30"; Persistent = true; };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/registry 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 5000 ];

  # no auth anywhere, ingress allowlist is the gate
  homelab.ingressOnly = {
    ports = [ 80 5000 ];
    extraSources = [
      "10.100.0.115/32"   # Forgejo CI runner
      "10.100.0.117/32"   # GitHub CI runners
      "10.100.0.118/32"   # registry-ui -> registry
      "10.200.0.209/32"   # Docker Swarm host that pulls the images
    ];
  };
}
