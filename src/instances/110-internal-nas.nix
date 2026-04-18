{ ... }: {
  networking.hostName = "vm-110";

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas/media      10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/documents  10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/public     10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/torrents   10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-110-nas";
        "map to guest" = "Bad User";
      };
      public = {
        path = "/srv/nas/public";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nobody";
        "force group" = "nogroup";
      };
      media = {
        path = "/srv/nas/media";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nobody";
        "force group" = "nogroup";
      };
      documents = {
        path = "/srv/nas/documents";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nobody";
        "force group" = "nogroup";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /srv/nas 0775 nobody nogroup -"
    "d /srv/nas/public 0775 nobody nogroup -"
    "d /srv/nas/media 0775 nobody nogroup -"
    "d /srv/nas/media/tv 0775 nobody nogroup -"
    "d /srv/nas/media/movies 0775 nobody nogroup -"
    "d /srv/nas/media/audiobooks 0775 nobody nogroup -"
    "d /srv/nas/documents 0775 nobody nogroup -"
    "d /srv/nas/torrents 0775 nobody nogroup -"
  ];

  networking.firewall.allowedTCPPorts = [ 2049 111 ];
  networking.firewall.allowedUDPPorts = [ 2049 111 ];
}
