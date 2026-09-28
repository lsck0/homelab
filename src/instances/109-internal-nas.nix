{ lib, pkgs, dmzShares, ... }: {
  networking.hostName = "vm-109";

  # kopia on vm-107 snapshots this tree

  # dmz exports come from dmzShares (modules/nas.nix)
  # ── bulk storage ───────────────────────────────────────────────────────────
  # hdd; media and torrents share a fs for hardlinks
  fileSystems."/srv/nas/bulk" = {
    device = "/dev/disk/by-label/bulk";
    fsType = "ext4";
    # nofail: state exports matter more than media
    options = [ "defaults" "nofail" "x-systemd.device-timeout=30s" ];
  };

  # formats once, guarded on the label
  systemd.services.bulk-format = {
    description = "Create the bulk filesystem on first boot";
    wantedBy = [ "multi-user.target" ];
    before = [ "srv-nas-bulk.mount" ];
    path = [ pkgs.util-linux pkgs.e2fsprogs ];
    unitConfig.ConditionPathExists = "!/dev/disk/by-label/bulk";
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      set -eu
      disk=/dev/sdb
      [ -b "$disk" ] || { echo "no $disk; nothing to format"; exit 0; }
      if blkid "$disk" >/dev/null 2>&1; then
        echo "$disk already carries a filesystem; refusing to format"
        exit 0
      fi
      # no partition table; 5% reserve would waste 90 GiB
      mkfs.ext4 -m 0 -L bulk "$disk"
    '';
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas/bulk       10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/bulk/media 10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/documents  10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/public     10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/bulk/torrents 10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/data       10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/syncthing  10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas            10.100.0.107(rw,sync,no_subtree_check,no_root_squash)
    '' + lib.concatStrings (lib.mapAttrsToList (id: shares: lib.concatMapStrings (s: ''
      /srv/nas/data/${s} 10.200.0.${id}(rw,sync,subtree_check,no_root_squash)
    '') shares) dmzShares);
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-109-nas";
        "map to guest" = "Bad User";
        # guest shares: owner pc, wireguard and tailnet only
        "hosts allow" = "192.168.178.138 10.0.0.0/24 100.64.0.0/10 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
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
        # media tree on the bulk disk
        path = "/srv/nas/bulk/media";
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
      BACKUPS = {
        path = "/srv/nas/BACKUPS";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "yes";
        "force user" = "nobody";
        "force group" = "nogroup";
      };
      syncthing = {
        path = "/srv/nas/syncthing";
        browseable = "yes";
        "read only" = "no";
        "guest ok" = "yes";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nobody";
        "force group" = "nogroup";
      };
      homelab = {
        path = "/srv/nas";
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

  # mdns so file managers find the nas
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
      userServices = true;
    };
  };

  systemd.tmpfiles.rules = [
    # root: tmpfiles refuses unsafe ownership transitions
    "d /srv/nas 0755 root root -"
    "d /srv/nas/public 0775 nobody nogroup -"
    # 1000: the uid every writing container uses
    "d /srv/nas/bulk 0775 1000 1000 -"
    "d /srv/nas/bulk/media 0775 1000 1000 -"
    "d /srv/nas/bulk/media/tv 0775 1000 1000 -"
    "d /srv/nas/bulk/media/movies 0775 1000 1000 -"
    "d /srv/nas/bulk/media/audiobooks 0775 1000 1000 -"
    "d /srv/nas/bulk/media/music 0775 1000 1000 -"
    "d /srv/nas/bulk/media/manga 0775 1000 1000 -"
    "d /srv/nas/bulk/media/anime 0775 1000 1000 -"
    "d /srv/nas/bulk/media/books 0775 1000 1000 -"
    "d /srv/nas/bulk/media/leaving-soon 0775 1000 1000 -"
    "d /srv/nas/BACKUPS 0700 root root -"
    # paperless (uid 315) consumes and deletes what smb drops here as nobody
    "d /srv/nas/documents 0777 nobody nogroup -"
    "d /srv/nas/bulk/torrents 0775 1000 1000 -"
    # per-service persistent data
    "d /srv/nas/data 0777 nobody nogroup -"
    # nightly db dumps, one subdir per vm
    "d /srv/nas/data/db-dumps 0777 nobody nogroup -"
    "d /srv/nas/data/authelia 0777 nobody nogroup -"
    "d /srv/nas/data/loki 0777 nobody nogroup -"
    "d /srv/nas/data/attic 0777 nobody nogroup -"
    "d /srv/nas/data/jellyseerr 0777 nobody nogroup -"
    "d /srv/nas/data/bazarr 0777 nobody nogroup -"
    "d /srv/nas/data/firefly 0777 nobody nogroup -"
    "d /srv/nas/data/firefly/db 0750 70 70 -"
    "d /srv/nas/data/firefly/upload 0750 1000 1000 -"
    "d /srv/nas/syncthing 0775 nobody nogroup -"
    "d /srv/nas/syncthing/sync 0775 nobody nogroup -"
    "d /var/lib/syncthing 0700 nobody nogroup -"
    "d /srv/nas/data/calendar 0777 nobody nogroup -"
    "d /srv/nas/data/forgejo 0777 nobody nogroup -"
    "d /srv/nas/data/forgejo-runner 0777 nobody nogroup -"
    "d /srv/nas/data/registry 0777 nobody nogroup -"
    "d /srv/nas/data/huginn 0777 nobody nogroup -"
    "d /srv/nas/data/huginn-db 0777 nobody nogroup -"
    "d /srv/nas/data/homeassistant 0777 nobody nogroup -"
    "d /srv/nas/data/grafana 0777 nobody nogroup -"
    "d /srv/nas/data/prometheus 0777 nobody nogroup -"
    "d /srv/nas/data/navidrome 0777 nobody nogroup -"
    "d /srv/nas/data/traefik-acme-internal 0777 nobody nogroup -"
    "d /srv/nas/data/paperless 0777 nobody nogroup -"
    "d /srv/nas/data/paperless-ai 0777 nobody nogroup -"
    "d /srv/nas/data/qbittorrent 0777 nobody nogroup -"
    "d /srv/nas/data/prowlarr 0777 nobody nogroup -"
    "d /srv/nas/data/sonarr 0777 nobody nogroup -"
    "d /srv/nas/data/radarr 0777 nobody nogroup -"
    "d /srv/nas/data/jellyfin 0777 nobody nogroup -"
    "d /srv/nas/data/homepage 0777 nobody nogroup -"
    "d /srv/nas/data/homepage-tokens 0777 nobody nogroup -"
    "d /srv/nas/data/crowdsec-internal 0777 nobody nogroup -"
    "d /srv/nas/data/lidarr 0777 nobody nogroup -"
    "d /srv/nas/data/janitorr 0777 nobody nogroup -"
    "d /var/lib/filebrowser 0750 1000 1000 -"
    "f /var/lib/filebrowser/filebrowser.db 0640 1000 1000 -"
  ] ++ map (s: "d /srv/nas/data/${s} 0777 nobody nogroup -") (lib.unique (lib.concatLists (lib.attrValues dmzShares)));

  # filebrowser, authelia gates it via traefik
  virtualisation.oci-containers.containers.filebrowser = {
    image = "filebrowser/filebrowser:v2.63.3";
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

  # syncthing gui at sync.lsck0.dev behind authelia
  systemd.services.syncthing.environment.HOME = "/var/lib/syncthing";
  services.syncthing = {
    enable = true;
    user = "nobody";
    group = "nogroup";
    dataDir = "/srv/nas/syncthing";
    configDir = "/var/lib/syncthing";
    guiAddress = "0.0.0.0:8384";
    overrideDevices = false;
    overrideFolders = false;
    settings.gui = {
      # authelia gates the route, skip own host check
      insecureSkipHostcheck = true;
    };

    settings.devices.luca-pc.id =
      "CJDJNIO-XF2HJN5-IOUMFGP-JLEPI4Q-IHEWABK-M4AFSV2-25VSZHA-NSBK3A3";

    # also the "syncthing" smb share
    settings.folders.sync = {
      id = "sync";
      path = "/srv/nas/syncthing/sync";
      devices = [ "luca-pc" ];
      type = "sendreceive";
      ignorePerms = true;
    };
  };



  networking.firewall.allowedTCPPorts = [ 80 2049 111 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 2049 111 22000 21027 ];

  # authelia is the only gate for 80 and 8384
  homelab.ingressOnly.ports = [ 80 8384 ];

  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
