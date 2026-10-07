{ lib, pkgs, inventory, site, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  repoDir = "/var/lib/archrepo";
  # vm-119 rsyncs the built repo here over ssh; the private half is its sops secret archrepo-push-key
  pushKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG9cIMqnQ/zKn2GxU/yTcEZlCZk+Ct8gx7GF2qzCrlXM archrepo-push@vm-119";
in {
  # push target for the builder; owns the served tree, the key only runs a write-only rsync into it
  users.users.archrepo = {
    isSystemUser = true;
    group = "archrepo";
    home = repoDir;
    # sshd runs the forced command through the login shell
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [ ''restrict,command="${pkgs.rrsync}/bin/rrsync -wo ${repoDir}" ${pushKey}'' ];
  };
  users.groups.archrepo = { };

  services.nginx = {
    enable = true;
    virtualHosts.archrepo = {
      default = true;
      root = repoDir;
      extraConfig = ''
        autoindex on;
      '';
      # the builder's dot directories are its state, not the repo
      locations."~ /\\.".return = "404";
      # build output the builder's untrusted container wrote (archrepo-build.sh push_logs): read, never rendered
      locations."~ ^/(logs/|build\\.log$)".extraConfig = ''
        types { }
        default_type text/plain;
        charset utf-8;
        add_header X-Content-Type-Options nosniff;
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d ${repoDir} 0755 archrepo archrepo -"
  ];

  # the home networks' pacman comes straight here (arch-dotfiles pacman.conf); public and signed, it bypasses nothing
  homelab.ingressOnly.portSources.${toString net.ports.http} = [ net.wan.subnet net.zones.internal.subnet net.wireguard.subnet ];
}
