# the nas: nfs exports (lib/nas-exports.nix), smb guest shares, syncthing, filebrowser, kopia (lib/kopia.nix), the
# lsck0 pacman repo vm-119 builds, and a full official arch mirror beside it
#
# The mirror (core/extra/multilib, x86_64) lives on the bulk hdd next to the lsck0 repo, so a -Syu or a pacstrap whose
# exact version is not in last night's lsck0 snapshot pulls from the lan instead of a 1.3 MB/s public mirror; the nvme
# root has no room for it. lib/archmirror-sync.sh says how a sync keeps the served tree whole. nginx serves it at
# /archlinux of the repo's vhost, so lsck0 keeps /x86_64 and its authority over overridden and aur packages (clients
# list it first). Symlinks stay enabled: the package files are relative links into the shared pool/ and rsync's
# --safe-links already bars any escape, so disable_symlinks would 404 every package.
{ config, lib, pkgs, inventory, site, catalog, ... }:
let
  net = import ../../modules/net.nix { inherit lib inventory site; };
  routes = catalog.internal;

  inherit (net) tailnet;

  bulk = "/srv/nas/bulk";
  bulkLabel = "bulk";
  bulkMount = "srv-nas-bulk.mount";
  # media and torrents together; the rest of the hdd stays free for the arch repo and whatever comes next
  mediaQuotaGiB = 750;
  # ext4 project id of everything under mediaDirs
  mediaProject = 1;
  mediaDirs = [ "${bulk}/media" "${bulk}/torrents" ];
  mediaLibraries = [ "tv" "movies" "music" "anime" "leaving-soon" ];

  archrepoPort = 8090;
  filebrowserPort = 8080;
  syncthingSyncPort = 22000;
  syncthingDiscoveryPort = 21027;

  mirrorDir = "${bulk}/archmirror";
  # tier 1, german, rsync-enabled; the trailing slash is the module root, already laid out as $repo/os/$arch
  mirrorUpstream = "rsync://ftp.halifax.rwth-aachen.de/archlinux/";
  # 1 GbE nas; cap the pull so a sync never starves live nfs serving or the nightly archbuild writes
  mirrorBwlimitKBps = 60 * 1024;
  mirrorLock = "/run/archmirror-sync.lock";
  mirrorSync = import ./lib/archmirror-sync.nix { inherit pkgs; };

  # every smb share is a guest share acting as nobody
  guestShare = { browseable = "yes"; "guest ok" = "yes"; "force user" = "nobody"; "force group" = "nogroup"; };
  guestShareWritable = path: guestShare // {
    inherit path;
    "read only" = "no";
    "create mask" = "0664";
    "directory mask" = "0775";
  };

  tokenDirOf = id: "/srv/nas/data/tokens/vm-${toString id}";
in {
  imports = [ ./lib/kopia.nix ./lib/nas-exports.nix ];

  networking.hostName = "vm-109";

  # hdd; media and torrents share a fs for hardlinks
  fileSystems.${bulk} = {
    device = "/dev/disk/by-label/${bulkLabel}";
    fsType = "ext4";
    # nofail: state exports matter more than media; noatime: a read must not write the hdd awake
    options = [ "defaults" "noatime" "nofail" "x-systemd.device-timeout=30s" ];
  };

  # the documents share's read-only view of the paperless archive; bindfs because paperless keeps the tree 0700
  fileSystems."/srv/nas/documents/archive" = {
    device = "/srv/nas/data/paperless/media/documents/archive";
    fsType = "fuse.bindfs";
    options = [ "ro" "perms=a+rX" "force-user=nobody" "force-group=nogroup" "allow_other" ];
  };
  system.fsPackages = [ pkgs.bindfs ];

  # ext4 turns on project quotas only while unmounted: an existing disk gets them on the next boot, never mid-deploy
  systemd.services.bulk-disk = {
    description = "Format the bulk disk when blank, enable its project quotas";
    wantedBy = [ "multi-user.target" ];
    before = [ bulkMount ];
    path = [ pkgs.util-linux pkgs.e2fsprogs pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
      [ -b "$disk" ] || { echo "no bulk disk attached"; exit 0; }
      # exit 2 is the only "no signature": a read error on a slow spin-up must never reformat
      rc=0; blkid -p "$disk" >/dev/null || rc=$?
      # no partition table, no root reserve: the quota leaves the room
      [ "$rc" = 2 ] && mkfs.ext4 -m 0 -O quota,project -E quotatype=prjquota -L ${bulkLabel} "$disk"
      tune2fs -l "$disk" | grep -q "^Filesystem features:.*project" && exit 0
      findmnt -S "$disk" >/dev/null && { echo "mounted: project quotas come on at the next boot"; exit 0; }
      tune2fs -O quota,project -Q prjquota "$disk"
    '';
  };

  # downloads and imports past the quota get EDQUOT, everything else keeps writing
  systemd.services.bulk-quota = {
    description = "Cap media and torrents on the bulk disk, export their usage";
    after = [ bulkMount ];
    requires = [ bulkMount ];
    wantedBy = [ "multi-user.target" ];
    startAt = "hourly";
    path = [ pkgs.e2fsprogs pkgs.quota pkgs.gawk pkgs.gnugrep pkgs.coreutils pkgs.findutils ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "bulk-quota"; };
    script = ''
      tune2fs -l /dev/disk/by-label/${bulkLabel} | grep -q "^Filesystem features:.*project" || { echo "no project quotas yet"; exit 0; }
      for d in ${lib.escapeShellArgs mediaDirs}; do
        # tag the tree once, marked done only after the whole walk; new files inherit the project from
        # their directory (+P exists on directories only)
        done_marker="$STATE_DIRECTORY/$(basename "$d").tagged"
        [ -e "$done_marker" ] && continue
        find "$d" -type f -exec chattr -p ${toString mediaProject} {} +
        find "$d" -type d -exec chattr -p ${toString mediaProject} +P {} +
        touch "$done_marker"
      done
      setquota -P ${toString mediaProject} 0 ${toString (mediaQuotaGiB * 1024 * 1024)} 0 0 ${bulk}
      quotaon -P ${bulk} 2>/dev/null || true
      used=$(repquota -Pn ${bulk} | awk '$1 == "#${toString mediaProject}" { print $3 * 1024 }')
      d=${config.homelab.textfileDir}
      {
        echo "# HELP homelab_media_bytes Bytes of media and torrents on the bulk disk."
        echo "# TYPE homelab_media_bytes gauge"
        echo "homelab_media_bytes ''${used:-0}"
        echo "# HELP homelab_media_quota_bytes Their quota."
        echo "# TYPE homelab_media_quota_bytes gauge"
        echo "homelab_media_quota_bytes ${toString (mediaQuotaGiB * 1024 * 1024 * 1024)}"
      } > $d/media_quota.prom.tmp
      mv $d/media_quota.prom.tmp $d/media_quota.prom
    '';
  };

  homelab.nasExports.enable = true;

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-109-nas";
        "map to guest" = "Bad User";
        # owner pc and notebook (dhcp-reserved in the fritzbox), wireguard and tailnet only
        "hosts allow" = "${site.lan.workstation} ${site.lan.notebook} ${net.wireguard.subnet} ${tailnet} 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";
      };
      public = guestShareWritable "/srv/nas/public";
      media = guestShareWritable "${bulk}/media";
      documents = guestShareWritable "/srv/nas/documents";
      BACKUPS = guestShare // { path = "/srv/nas/BACKUPS"; "read only" = "yes"; };
      syncthing = guestShareWritable "/srv/nas/syncthing";
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
    "d ${bulk} 0775 1000 1000 -"
    "d ${bulk}/media 0775 1000 1000 -"
  ] ++ map (library: "d ${bulk}/media/${library} 0775 1000 1000 -") mediaLibraries ++ [
    "d /srv/nas/BACKUPS 0700 root root -"
    # terraform state, pushed by sync.sh; it holds secrets, so neither smb nor filebrowser may read it
    "d /srv/nas/terraform 0700 root root -"
    # read-only root: documents go into inbox/, archive/ is the paperless view
    "d /srv/nas/documents 0755 nobody nogroup -"
    # paperless (uid 315) consumes and deletes what smb drops here as nobody
    "d /srv/nas/documents/inbox 0777 nobody nogroup -"
    "d ${bulk}/torrents 0775 1000 1000 -"
    # vm-119 writes as root over nfs
    "d ${bulk}/archrepo 0755 root root -"
    "d ${mirrorDir} 0755 root root -"
    "d /srv/nas/data/firefly/db 0750 70 70 -"
    "d /srv/nas/data/firefly/upload 0750 1000 1000 -"
    "d /srv/nas/syncthing 0775 nobody nogroup -"
    "d /srv/nas/syncthing/sync 0775 nobody nogroup -"
    "d /var/lib/syncthing 0700 nobody nogroup -"
    "d /var/lib/filebrowser 0750 1000 1000 -"
    "f /var/lib/filebrowser/filebrowser.db 0640 1000 1000 -"
  ];

  virtualisation.oci-containers.containers.filebrowser = {
    image = "filebrowser/filebrowser:v2.63.3";
    ports = [ "${toString routes.nas.port}:${toString filebrowserPort}" ];
    volumes = [
      "/srv/nas:/srv"
      "/var/lib/filebrowser/filebrowser.db:/database/filebrowser.db"
    ];
    environment = {
      # authelia gates the route
      FB_NOAUTH = "true";
      FB_DATABASE = "/database/filebrowser.db";
      FB_ROOT = "/srv";
      FB_PORT = toString filebrowserPort;
    };
  };

  systemd.services.syncthing.environment.HOME = "/var/lib/syncthing";
  services.syncthing = {
    enable = true;
    user = "nobody";
    group = "nogroup";
    dataDir = "/srv/nas/syncthing";
    configDir = "/var/lib/syncthing";
    guiAddress = "0.0.0.0:${toString routes.syncthing.port}";
    overrideDevices = false;
    overrideFolders = false;
    # authelia gates the route, so the gui skips its own host check
    settings.gui.insecureSkipHostcheck = true;
    # both devices reach the nas directly (lan or wireguard): no discovery servers, relays or reports
    settings.options = {
      urAccepted = -1;
      crashReportingEnabled = false;
      globalAnnounceEnabled = false;
      relaysEnabled = false;
      natEnabled = false;
    };

    settings.devices.luca-pc.id = "CJDJNIO-XF2HJN5-IOUMFGP-JLEPI4Q-IHEWABK-M4AFSV2-25VSZHA-NSBK3A3";
    settings.devices.luca-notebook.id = "MI7TZZS-PGXBWLU-YIPVZ2T-EX4AR5F-LKCWYF7-CSZWHBD-JDPSKKI-RXRUXAX";

    # also the "syncthing" smb share
    settings.folders.sync = {
      id = "sync";
      path = "/srv/nas/syncthing/sync";
      devices = [ "luca-pc" "luca-notebook" ];
      type = "sendreceive";
      ignorePerms = true;
    };
  };

  # plain http: the packages and the db are signed
  services.nginx = {
    enable = true;
    virtualHosts.archrepo = {
      listen = [{ addr = "0.0.0.0"; port = archrepoPort; }];
      root = "${bulk}/archrepo";
      extraConfig = ''
        autoindex on;
        # internal, lan, wireguard, tailnet
        allow ${net.zones.internal.subnet};
        allow ${net.wan.subnet};
        allow ${net.wireguard.subnet};
        allow ${tailnet};
        deny all;
      '';
      # builder state, and the mirror's .~tmp~ staging dirs mid-sync
      locations."~ /\\.".return = "404";
      locations."/archlinux/" = {
        alias = "${mirrorDir}/";
        extraConfig = ''
          autoindex on;
          default_type application/octet-stream;
          types {
            application/octet-stream db sig zst;
            text/plain txt;
          }
          add_header X-Content-Type-Options nosniff;
        '';
      };
    };
  };

  # a token an app minted once (an admin password it was set up with) must move from the old shared dir, a fresh one
  # would not log in; what stays behind belongs to no registered producer (modules/tokens)
  systemd.services.lab-tokens-migrate = {
    description = "Move tokens from the shared homepage-tokens dir into their producers' dirs";
    wantedBy = [ "multi-user.target" ];
    before = [ "nfs-server.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      old=/srv/nas/data/homepage-tokens
      [ -d "$old" ] || exit 0
      ${lib.concatStrings (lib.mapAttrsToList (name: id: ''
        if [ -e "$old/${name}.token" ] && [ ! -e ${tokenDirOf id}/${name}.token ]; then
          ${pkgs.coreutils}/bin/install -d -m 0777 ${tokenDirOf id}
          ${pkgs.coreutils}/bin/mv -n "$old/${name}.token" ${tokenDirOf id}/
          echo "moved ${name} to vm-${toString id}"
        fi
      '') config.homelab.tokens.producers)}
    '';
  };

  # official repos update a few times a day, so hourly caps the lag; flock drops a tick the slow first sync overlaps
  systemd.services.archmirror-sync = {
    description = "Sync the full official Arch mirror (core/extra/multilib, x86_64) from a tier-1 upstream";
    after = [ "network-online.target" bulkMount ];
    wants = [ "network-online.target" ];
    requires = [ bulkMount ];
    startAt = "hourly";
    environment = {
      ARCHMIRROR_UPSTREAM = mirrorUpstream;
      ARCHMIRROR_TARGET = mirrorDir;
      ARCHMIRROR_BWLIMIT_KBPS = toString mirrorBwlimitKBps;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/flock -n ${mirrorLock} ${lib.getExe mirrorSync}";
      # behind live nfs serving and the nightly archbuild
      IOSchedulingClass = "idle";
      Nice = 19;
    };
  };

  networking.firewall.allowedTCPPorts = [ routes.nas.port archrepoPort routes.syncthing.port syncthingSyncPort ];
  networking.firewall.allowedUDPPorts = [ syncthingSyncPort syncthingDiscoveryPort ];

  # authelia is the only gate of filebrowser and the syncthing gui
  homelab.ingressOnly.ports = [ routes.nas.port routes.syncthing.port ];

  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
