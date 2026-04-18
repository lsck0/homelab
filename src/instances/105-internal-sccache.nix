{ pkgs, ... }: {
  networking.hostName = "vm-105";

  services.redis.servers.sccache = {
    enable = true;
    port = 6379;
    bind = "0.0.0.0";
    extraConfig = ''
      protected-mode no
      maxmemory 2gb
      maxmemory-policy allkeys-lru
      appendonly yes
    '';
  };

  environment.systemPackages = [ pkgs.sccache ];

  networking.firewall.allowedTCPPorts = [ 6379 ];
}
