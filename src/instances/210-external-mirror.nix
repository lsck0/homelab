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
    # activation resets the home to homeMode (700) on every switch, nginx must read it
    homeMode = "755";
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

  # external traefik plus the home networks, whose pacman goes straight to 10.200.0.210 (arch-dotfiles lsck0.conf);
  # the repo is public and signed, so skipping traefik bypasses nothing. 22 stays open for the builder push
  homelab.ingressOnly = {
    ports = [ 80 ];
    # fritzbox lan, internal lan, wireguard
    portSources."80" = [ "192.168.178.0/24" "10.100.0.0/24" "10.0.0.0/24" ];
  };
}
