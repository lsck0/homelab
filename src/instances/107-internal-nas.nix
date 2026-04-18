{ ... }: {
  networking.hostName = "vm-107";

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-107-nas";
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
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  systemd.tmpfiles.rules = [
    "d /srv/nas 0775 nobody nogroup -"
    "d /srv/nas/public 0775 nobody nogroup -"
  ];
}
