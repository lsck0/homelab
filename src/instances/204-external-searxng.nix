{ pkgs, ... }:
let
  secret = "/var/lib/searxng/secret";
  settings = pkgs.writeText "searxng-settings.yml" ''
    use_default_settings: true
    server:
      bind_address: "0.0.0.0"
      port: 8080
      secret_key: "@SECRET@"
      # the limiter needs a valkey beside it
      limiter: false
      image_proxy: true
    search:
      safe_search: 0
      # autocomplete would send every keystroke to the provider
      autocomplete: ""
  '';
in {
  networking.hostName = "vm-204";

  # no nas share: settings are rewritten every start, only the secret key is state
  systemd.services.podman-searxng.preStart = ''
    # generated here, a literal would be public in this repo
    [ -s ${secret} ] || (umask 077; head -c 32 /dev/urandom | base64 | tr -d '/+=' > ${secret})
    sed "s|@SECRET@|$(cat ${secret})|" ${settings} > /var/lib/searxng/settings.yml
    chown 1000:1000 /var/lib/searxng/settings.yml
  '';

  virtualisation.oci-containers.containers.searxng = {
    image = "searxng/searxng:2026.9.16-461f174b0";
    ports = [ "80:8080" ];
    volumes = [ "/var/lib/searxng:/etc/searxng" ];
    environment = {
      SEARXNG_BASE_URL = "https://search.lsck0.dev/";
    };
    # ~140 MiB: vm 30d peak 393 minus the idle base
    extraOptions = [ "--memory=256m" ];
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/searxng 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];
}
