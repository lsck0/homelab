{ pkgs, nasMount, ... }: {
  networking.hostName = "vm-202";

  fileSystems = nasMount "/var/lib/searxng" "searxng";

  # Write default settings.yml if missing (fresh install)
  systemd.services.searxng-config = {
    description = "Ensure SearXNG settings exist";
    before = [ "podman-searxng.service" ];
    requiredBy = [ "podman-searxng.service" ];
    serviceConfig.Type = "oneshot";
    path = [ pkgs.coreutils ];
    script = ''
      if [ ! -f /var/lib/searxng/settings.yml ]; then
        cat > /var/lib/searxng/settings.yml << 'YAML'
      use_default_settings: true
      server:
        bind_address: "0.0.0.0"
        port: 8080
        secret_key: "searxng-homelab-secret-$(head -c 32 /dev/urandom | base64)"
        limiter: false
        image_proxy: true
      search:
        safe_search: 0
        autocomplete: "google"
      YAML
        chown 1000:1000 /var/lib/searxng/settings.yml
      fi
    '';
  };

  virtualisation.oci-containers.containers.searxng = {
    image = "searxng/searxng:latest";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/searxng:/etc/searxng" ];
    environment = {
      SEARXNG_BASE_URL = "https://search.lsck0.dev/";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
