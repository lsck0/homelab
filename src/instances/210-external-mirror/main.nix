{ lib, pkgs, lab, ... }:
let
  repoDir = "/var/lib/archrepo";
  # the builder rsyncs the built repo here over ssh; the public half lives beside the private one, its secret
  pushSecret = "archrepo-push-key";
  pusher = lib.findSingle (i: i.config.secrets ? ${pushSecret}) (throw "no instance holds ${pushSecret}")
    (throw "two instances hold ${pushSecret}") (lib.attrValues lab.instances);
  pushKey = lib.fileContents (pusher.dir + "/archrepo-push.pub");
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
}
