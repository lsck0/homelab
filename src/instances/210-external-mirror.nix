{ pkgs, ... }:
let
  repoDir = "/var/lib/archrepo";
  # vm-119 rsyncs the built repo here over ssh; this host only serves it
  pushKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9cIMqnQ/zKn2GxU/yTcEZlCZk+Ct8gx7GF2qzCrlXM archrepo-push@vm-119";
in {
  networking.hostName = "vm-210";

  # push target for the builder; owns the served tree, no shell beyond rsync/scp over ssh
  users.users.archrepo = {
    isSystemUser = true;
    group = "archrepo";
    home = repoDir;
    createHome = true;
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [ pushKey ];
  };
  users.groups.archrepo = { };

  # the lsck0 pacman repo, served read-only; packages and db are signed
  services.nginx = {
    enable = true;
    virtualHosts.archrepo = {
      default = true;
      root = repoDir;
      extraConfig = ''
        autoindex on;
      '';
      # builder state directory
      locations."~ /\\.".return = "404";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${repoDir} 0755 archrepo archrepo -"
  ];

  networking.firewall.allowedTCPPorts = [ 80 ];

  # external traefik is the only path to :80; 22 stays open for the builder push
  homelab.ingressOnly.ports = [ 80 ];
}
