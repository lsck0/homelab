{ nasMount, ... }: {
  networking.hostName = "vm-111";

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas/media      10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/documents  10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/public     10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/torrents   10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/data       10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/data       10.200.0.0/24(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-111-nas";
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
    "d /srv/nas/media/music 0775 nobody nogroup -"
    "d /srv/nas/media/manga 0775 nobody nogroup -"
    "d /srv/nas/documents 0775 nobody nogroup -"
    "d /srv/nas/torrents 0775 nobody nogroup -"
    # per-service persistent data
    "d /srv/nas/data 0777 nobody nogroup -"
    "d /srv/nas/data/authentik 0777 nobody nogroup -"
    "d /srv/nas/data/forgejo 0777 nobody nogroup -"
    "d /srv/nas/data/registry 0777 nobody nogroup -"
    "d /srv/nas/data/taskchampion 0777 nobody nogroup -"
    "d /srv/nas/data/vaultwarden 0777 nobody nogroup -"
    "d /srv/nas/data/nextcloud 0777 nobody nogroup -"
    "d /srv/nas/data/nextcloud-db 0777 nobody nogroup -"
    "d /srv/nas/data/wikijs-db 0777 nobody nogroup -"
    "d /srv/nas/data/huginn 0777 nobody nogroup -"
    "d /srv/nas/data/huginn-db 0777 nobody nogroup -"
    "d /srv/nas/data/homeassistant 0777 nobody nogroup -"
    "d /srv/nas/data/grafana 0777 nobody nogroup -"
    "d /srv/nas/data/prometheus 0777 nobody nogroup -"
    "d /srv/nas/data/navidrome 0777 nobody nogroup -"
    "d /srv/nas/data/kavita 0777 nobody nogroup -"
    "d /srv/nas/data/uptime-kuma 0777 nobody nogroup -"
    "d /srv/nas/data/shlink 0777 nobody nogroup -"
    "d /srv/nas/data/privatebin 0777 nobody nogroup -"
    "d /srv/nas/data/share 0777 nobody nogroup -"
    "d /srv/nas/data/minecraft 0777 nobody nogroup -"
    "d /srv/nas/data/minecraft-modpacks 0777 nobody nogroup -"
    "d /srv/nas/data/paperless 0777 nobody nogroup -"
    "d /srv/nas/data/qbittorrent 0777 nobody nogroup -"
    "d /srv/nas/data/prowlarr 0777 nobody nogroup -"
    "d /srv/nas/data/sonarr 0777 nobody nogroup -"
    "d /srv/nas/data/radarr 0777 nobody nogroup -"
    "d /srv/nas/data/jellyfin 0777 nobody nogroup -"
    "d /srv/nas/data/audiobookshelf 0777 nobody nogroup -"
    "d /srv/nas/data/homepage 0777 nobody nogroup -"
    "d /srv/nas/data/homepage-tokens 0777 nobody nogroup -"
    "d /srv/nas/data/crowdsec-internal 0777 nobody nogroup -"
    "d /srv/nas/data/crowdsec-external 0777 nobody nogroup -"
    "d /var/lib/filebrowser 0750 1000 1000 -"
    "f /var/lib/filebrowser/filebrowser.db 0640 1000 1000 -"
  ];

  # FileBrowser web UI — authentik handles auth via traefik
  virtualisation.oci-containers.containers.filebrowser = {
    image = "filebrowser/filebrowser:latest";
    ports = [ "80:8080" ];
    volumes = [
      "/srv/nas:/srv"
      "/var/lib/filebrowser/filebrowser.db:/database/filebrowser.db"
    ];
    environment = {
      FB_NOAUTH = "true";
      FB_DATABASE = "/database/filebrowser.db";
      FB_ROOT = "/srv";
      FB_PORT = "8080";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 2049 111 ];
  networking.firewall.allowedUDPPorts = [ 2049 111 ];
}
