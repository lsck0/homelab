{ lib, pkgs, dmzShares, ... }: {
  networking.hostName = "vm-109";

  # backups: Kopia on vm-107 snapshots this tree (see 106-internal-kopia.nix).

  # DMZ exports come from dmzShares (modules/nas.nix), one share per VM address.
  # subtree_check: all shares live on one filesystem, and without it a root
  # client can forge file handles that reach outside its share.
  # ── bulk storage ───────────────────────────────────────────────────────────
  # scsi1, the spinning disk. media and torrents share one filesystem so the *arr stack can hardlink between them.
  fileSystems."/srv/nas/bulk" = {
    device = "/dev/disk/by-label/bulk";
    fsType = "ext4";
    # nofail: the service-state exports matter more than media
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
      # no partition table; -m 0 because a 5% reserve here is 90 GiB wasted
      mkfs.ext4 -m 0 -L bulk "$disk"
    '';
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /srv/nas/bulk/media 10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/documents  10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/public     10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/bulk/torrents 10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
      /srv/nas/data       10.100.0.0/24(rw,sync,no_subtree_check,no_root_squash)
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
      BACKUPS = {
        path = "/srv/nas/BACKUPS";
        browseable = "yes";
        "read only" = "yes";
        "guest ok" = "yes";
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

  # mDNS advertisement: lets file managers (Nemo, Nautilus, Finder) auto-discover the NAS
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
    # root, not nobody: systemd-tmpfiles refuses to descend when ownership
    # changes from one non-root user to another ("Detected unsafe path
    # transition"), so a nobody-owned /srv/nas silently blocked every rule
    # for the 1000-owned media tree below it. A root-owned parent is exempt.
    # Nothing writes into /srv/nas itself; every share is a subdirectory.
    "d /srv/nas 0755 root root -"
    "d /srv/nas/public 0775 nobody nogroup -"
    # 1000, not nobody: every container that writes here (the *arr stack and
    # qbittorrent, via homelab.servarr and 111) runs as PUID 1000, which
    # LinuxServer images call "abc". Against a 0775 tree owned by 65534 they
    # could read but not write, and Radarr refused its own root folder with
    #   Folder '/data/media/movies/' is not writable by user 'abc'
    # The readers (Jellyfin, Audiobookshelf, Kavita, Navidrome) only need the
    # o+rx that 0775 already gives them.
    # creates the tree on whatever is mounted at /srv/nas/bulk
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
    "d /srv/nas/documents 0775 nobody nogroup -"
    "d /srv/nas/bulk/torrents 0775 1000 1000 -"
    # per-service persistent data
    "d /srv/nas/data 0777 nobody nogroup -"
    # nightly database dumps (modules/db-backup.nix), one subdir per VM. This is
    # what makes the Kopia snapshot contain a restorable copy of the databases
    # rather than a byte copy of live data directories.
    "d /srv/nas/data/db-dumps 0777 nobody nogroup -"
    "d /srv/nas/data/authelia 0777 nobody nogroup -"
    "d /srv/nas/data/loki 0777 nobody nogroup -"
    "d /srv/nas/data/attic 0777 nobody nogroup -"
    "d /srv/nas/data/jellyseerr 0777 nobody nogroup -"
    "d /srv/nas/data/bazarr 0777 nobody nogroup -"
    "d /srv/nas/data/firefly 0777 nobody nogroup -"
    "d /srv/nas/data/firefly/db 0750 999 999 -"
    "d /srv/nas/data/firefly/upload 0750 1000 1000 -"
    "d /srv/nas/syncthing 0775 nobody nogroup -"
    "d /var/lib/syncthing 0700 nobody nogroup -"
    "d /srv/nas/data/calendar 0777 nobody nogroup -"
    "d /srv/nas/data/forgejo 0777 nobody nogroup -"
    "d /srv/nas/data/forgejo-runner 0777 nobody nogroup -"
    "d /srv/nas/data/registry 0777 nobody nogroup -"
    "d /srv/nas/data/vaultwarden 0777 nobody nogroup -"
    "d /srv/nas/data/nextcloud 0777 nobody nogroup -"
    "d /srv/nas/data/nextcloud-db 0777 nobody nogroup -"
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
    "d /srv/nas/data/bookshelf 0777 nobody nogroup -"
    "d /srv/nas/data/janitorr 0777 nobody nogroup -"
    "d /srv/nas/data/hermes 0777 nobody nogroup -"
    "d /var/lib/filebrowser 0750 1000 1000 -"
    "f /var/lib/filebrowser/filebrowser.db 0640 1000 1000 -"
  ] ++ map (s: "d /srv/nas/data/${s} 0777 nobody nogroup -") (lib.unique (lib.concatLists (lib.attrValues dmzShares)));

  # FileBrowser web UI: authelia handles auth via traefik
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

  # Syncthing: continuous device sync, complements SMB/NFS
  # GUI at sync.lsck0.dev behind Authelia; sync protocol on 22000 (LAN only,
  # not port-forwarded). Data lives under the NAS tree so it is backed up.
  # syncthing panics with "$HOME is not defined" under the home-less `nobody`
  # user, so give the service an explicit HOME (its config dir).
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
      # Authelia ForwardAuth gates the route; disable Syncthing's own auth so it
      # does not double-prompt, and keep the GUI off the public port.
      insecureSkipHostcheck = true;
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 2049 111 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 2049 111 22000 21027 ];

  # FileBrowser runs with FB_NOAUTH and the Syncthing GUI has its own auth
  # disabled, both because Authelia gates their routes. NFS (2049/111), SMB and
  # the Syncthing sync protocol (22000) are untouched: they are the actual file
  # services and carry their own access control.
  homelab.ingressOnly.ports = [ 80 8384 ];
}
