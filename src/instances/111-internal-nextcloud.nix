{ pkgs, config, ... }: {
  networking.hostName = "vm-111";

  sops.secrets.nextcloud-admin-pass.owner = "nextcloud";

  services.nextcloud = {
    enable = true;
    hostName = "cloud.internal.local";
    config.dbtype = "sqlite";
    config.adminpassFile = config.sops.secrets.nextcloud-admin-pass.path;
    package = pkgs.nextcloud33;
  };

  networking.firewall.allowedTCPPorts = [ 80 ];
}
