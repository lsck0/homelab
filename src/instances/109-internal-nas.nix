{ config, lib, pkgs, inventory, nasClients, site, ... }:
let
  # media and torrents together; the rest of the hdd stays free for the arch repo and whatever comes next
  mediaQuotaGiB = 750;
  # ext4 project id of everything under mediaDirs
  mediaProject = 1;
  mediaDirs = [ "/srv/nas/bulk/media" "/srv/nas/bulk/torrents" ];

  dataRoot = "/srv/nas/data";
  dataShares = lib.filter (lib.hasPrefix "${dataRoot}/") (lib.attrNames clientsByPath);
  # "/srv/nas/data/a/b/c" -> [ "/srv/nas/data/a" "/srv/nas/data/a/b" ]
  parentsOf = path: let parts = lib.splitString "/" (lib.removePrefix "${dataRoot}/" path); in
    map (n: "${dataRoot}/${lib.concatStringsSep "/" (lib.take n parts)}") (lib.range 1 (lib.length parts - 1));

  # dmz and apps zone clients get subtree checks
  internalIps = map (v: v.ip) (lib.filter (v: v.type == "internal") (lib.attrValues inventory));

  # every guest's nas mounts as { path, ip, readOnly }, grouped by path
  clientsByPath = lib.groupBy (c: c.path)
    (lib.concatLists (lib.mapAttrsToList (ip: map (s: s // { inherit ip; })) nasClients));
  exportOptions = c: lib.concatStringsSep "," ([
    (if c.readOnly then "ro" else "rw") "sync" "no_root_squash"
    (if lib.elem c.ip internalIps then "no_subtree_check" else "subtree_check")
  ]
  # a missing hdd must not export the empty mountpoint on the nvme
  ++ lib.optional (lib.hasPrefix "/srv/nas/bulk" c.path) "mp=/srv/nas/bulk");

  # full official arch mirror (core/extra/multilib, x86_64), served beside the lsck0 repo so a -Syu or a
  # pacstrap whose exact version is not in last night's lsck0 snapshot pulls from the lan, not a 1.3 MB/s
  # public mirror. lives on the bulk hdd next to archrepo: the nvme root has no room, the hdd keeps ~1 TiB free.
  mirrorDir = "/srv/nas/bulk/archmirror";
  # tier-1 upstream that allows rsync and carries the full tree. rwth aachen: german, tier 1, rsync-enabled.
  # the trailing slash is the rsync module root, whose layout is already $repo/os/$arch.
  mirrorUpstream = "rsync://ftp.halifax.rwth-aachen.de/archlinux/";
  # 1 GbE nas; cap the pull so a sync never starves live nfs serving or the nightly archbuild writes
  mirrorBwlimitKBps = 60 * 1024;
  mirrorLock = "/run/archmirror-sync.lock";

  # official two-stage method: --delay-updates stages every changed file in a .~tmp~ dir and renames the
  # whole batch into place only after a clean transfer, so nginx never serves a half-synced tree;
  # --delete-after removes stale files last. the module's lastupdate file arrives with the tree and, once
  # it matches upstream, gates the next run so an unchanged upstream costs one tiny transfer, not a full pass.
  mirrorSync = pkgs.writeShellScript "archmirror-sync" ''
    set -euo pipefail
    upstream=${lib.escapeShellArg mirrorUpstream}
    target=${lib.escapeShellArg mirrorDir}
    ${pkgs.coreutils}/bin/mkdir -p "$target"

    tmp_lastupdate=$(${pkgs.coreutils}/bin/mktemp)
    trap '${pkgs.coreutils}/bin/rm -f "$tmp_lastupdate"' EXIT
    if ${pkgs.rsync}/bin/rsync -q --no-motd "''${upstream}lastupdate" "$tmp_lastupdate" \
       && ${pkgs.diffutils}/bin/cmp -s "$tmp_lastupdate" "$target/lastupdate"; then
      echo "archmirror: upstream unchanged, nothing to sync"
      exit 0
    fi

    # -rtlH -p preserves times, symlinks, hardlinks and perms; --safe-links drops any symlink escaping the
    # tree (core/extra/multilib link package files into the shared pool/ with relative links, which stay).
    # /iso and /sources are the only excludes; the tree measured 122 GiB after the first full sync (2026-10).
    ${pkgs.rsync}/bin/rsync \
      -rtlH -p --safe-links --no-motd \
      --delay-updates --delete-after --delete-excluded \
      --timeout=600 --contimeout=60 \
      --bwlimit=${toString mirrorBwlimitKBps} \
      --exclude='/iso' --exclude='/sources' --exclude='*.links.tar.gz*' \
      "$upstream" "$target/"
  '';
in {
  # kopia snapshots this tree in place
  imports = [ ../services/kopia.nix ];

  networking.hostName = "vm-109";

  # hdd; media and torrents share a fs for hardlinks
  fileSystems."/srv/nas/bulk" = {
    device = "/dev/disk/by-label/bulk";
    fsType = "ext4";
    # nofail: state exports matter more than media; noatime: a read must not write the hdd awake
    options = [ "defaults" "noatime" "nofail" "x-systemd.device-timeout=30s" ];
  };

  # the documents share shows every paperless document, however it was added: a read-only view of
  # the searchable pdf archive (<year>/<correspondent>/<date> <title>.pdf) next to the inbox paperless consumes
  # bindfs, not a bind mount: paperless keeps the tree 0700, the smb guest must be able to read it
  fileSystems."/srv/nas/documents/archive" = {
    device = "/srv/nas/data/paperless/media/documents/archive";
    fsType = "fuse.bindfs";
    options = [ "ro" "perms=a+rX" "force-user=nobody" "force-group=nogroup" "allow_other" ];
  };
  system.fsPackages = [ pkgs.bindfs ];

  # formats a blank disk once and turns on project quotas, which ext4 only allows while unmounted:
  # an existing disk gets them on the nas's next boot, never mid-deploy
  systemd.services.bulk-disk = {
    description = "Format the bulk disk when blank, enable its project quotas";
    wantedBy = [ "multi-user.target" ];
    before = [ "srv-nas-bulk.mount" ];
    path = [ pkgs.util-linux pkgs.e2fsprogs pkgs.gnugrep ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
      [ -b "$disk" ] || { echo "no bulk disk attached"; exit 0; }
      # exit 2 is the only "no signature": a read error on a slow spin-up must never reformat
      rc=0; blkid -p "$disk" >/dev/null || rc=$?
      # no partition table, no root reserve: the quota leaves the room
      [ "$rc" = 2 ] && mkfs.ext4 -m 0 -O quota,project -E quotatype=prjquota -L bulk "$disk"
      tune2fs -l "$disk" | grep -q "^Filesystem features:.*project" && exit 0
      findmnt -S "$disk" >/dev/null && { echo "mounted: project quotas come on at the next boot"; exit 0; }
      tune2fs -O quota,project -Q prjquota "$disk"
    '';
  };

  # caps media plus torrents at mediaQuotaGiB: downloads and imports get EDQUOT, everything else keeps writing
  systemd.services.bulk-quota = {
    description = "Cap media and torrents on the bulk disk, export their usage";
    after = [ "srv-nas-bulk.mount" ];
    requires = [ "srv-nas-bulk.mount" ];
    wantedBy = [ "multi-user.target" ];
    startAt = "hourly";
    path = [ pkgs.e2fsprogs pkgs.quota pkgs.gawk pkgs.gnugrep pkgs.coreutils pkgs.findutils ];
    serviceConfig = { Type = "oneshot"; StateDirectory = "bulk-quota"; };
    script = ''
      tune2fs -l /dev/disk/by-label/bulk | grep -q "^Filesystem features:.*project" || { echo "no project quotas yet"; exit 0; }
      for d in ${lib.escapeShellArgs mediaDirs}; do
        # tag the tree once, marked done only after the whole walk; new files inherit the project from
        # their directory (+P exists on directories only)
        done_marker="$STATE_DIRECTORY/$(basename "$d").tagged"
        [ -e "$done_marker" ] && continue
        find "$d" -type f -exec chattr -p ${toString mediaProject} {} +
        find "$d" -type d -exec chattr -p ${toString mediaProject} +P {} +
        touch "$done_marker"
      done
      setquota -P ${toString mediaProject} 0 ${toString (mediaQuotaGiB * 1024 * 1024)} 0 0 /srv/nas/bulk
      quotaon -P /srv/nas/bulk 2>/dev/null || true
      used=$(repquota -Pn /srv/nas/bulk | awk '$1 == "#${toString mediaProject}" { print $3 * 1024 }')
      d=/var/lib/node-exporter-textfile
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


  # each guest gets exactly the paths it mounts; the dmz additionally gets subtree checks
  services.nfs.server = {
    enable = true;
    exports = lib.concatStrings (lib.mapAttrsToList (path: clients:
      "${path} ${lib.concatMapStringsSep " " (c: "${c.ip}(${exportOptions c})") clients}\n"
    ) clientsByPath);
  };

  # nfsd sizes its largest rpc from the ram it sees at start; restarted while ballooned down it shrinks below
  # what clients negotiated at boot, and every hard mount hangs on "RPC fragment too large"
  systemd.services.nfs-server.serviceConfig.ExecStartPre = [ "${pkgs.bash}/bin/sh -c 'echo 1048576 > /proc/fs/nfsd/max_block_size'" ];

  # nixpkgs' nfsd module restarts only mountd when /etc/exports changes, and only nfs-server's start runs exportfs:
  # a share added by a deploy stays unexported, and its clients get "No such file or directory", until a reboot
  systemd.services.nfs-exports-reload = {
    description = "Re-export the NAS shares after /etc/exports changes";
    after = [ "nfs-server.service" ];
    requires = [ "nfs-server.service" ];
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ config.environment.etc.exports.source ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.nfs-utils}/bin/exportfs -ra";
    };
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        workgroup = "WORKGROUP";
        "server string" = "vm-109-nas";
        "map to guest" = "Bad User";
        # guest shares: owner pc and notebook (dhcp-reserved in the fritzbox), wireguard and tailnet only
        "hosts allow" = "${site.lan.workstation} ${site.lan.notebook} 10.0.0.0/24 100.64.0.0/10 127.0.0.1";
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
    "d /srv/nas/bulk/media/music 0775 1000 1000 -"
    "d /srv/nas/bulk/media/anime 0775 1000 1000 -"
    "d /srv/nas/bulk/media/leaving-soon 0775 1000 1000 -"
    "d /srv/nas/BACKUPS 0700 root root -"
    # terraform state, pushed by sync.sh; it holds secrets, so neither smb nor filebrowser may read it
    "d /srv/nas/terraform 0700 root root -"
    # read-only root: documents go into inbox/, archive/ is the paperless view
    "d /srv/nas/documents 0755 nobody nogroup -"
    # paperless (uid 315) consumes and deletes what smb drops here as nobody
    "d /srv/nas/documents/inbox 0777 nobody nogroup -"
    "d /srv/nas/bulk/torrents 0775 1000 1000 -"
    # vm-119 writes as root over nfs, nginx serves it on 8090
    "d /srv/nas/bulk/archrepo 0755 root root -"
    # full official mirror, rsynced in place by archmirror-sync, nginx serves it at /archlinux
    "d /srv/nas/bulk/archmirror 0755 root root -"
    "d /srv/nas/data/firefly/db 0750 70 70 -"
    "d /srv/nas/data/firefly/upload 0750 1000 1000 -"
    "d /srv/nas/syncthing 0775 nobody nogroup -"
    "d /srv/nas/syncthing/sync 0775 nobody nogroup -"
    "d /var/lib/syncthing 0700 nobody nogroup -"
    "d /var/lib/filebrowser 0750 1000 1000 -"
    "f /var/lib/filebrowser/filebrowser.db 0640 1000 1000 -"
  ]
  # per-service state: every share a guest mounts, any uid may write it
  ++ map (path: "d ${path} 0777 nobody nogroup -") dataShares
  # tmpfiles' d makes no missing parents: a nested share (tokens/vm-140) needs its parents spelled out
  ++ map (path: "d ${path} 0755 root root -") (lib.subtractLists dataShares (lib.unique (lib.concatMap parentsOf dataShares)));

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
    # both devices reach the nas directly (lan or wireguard): no discovery servers, relays or reports
    settings.options = {
      urAccepted = -1;
      crashReportingEnabled = false;
      globalAnnounceEnabled = false;
      relaysEnabled = false;
      natEnabled = false;
    };

    settings.devices.luca-pc.id =
      "CJDJNIO-XF2HJN5-IOUMFGP-JLEPI4Q-IHEWABK-M4AFSV2-25VSZHA-NSBK3A3";
    settings.devices.luca-notebook.id =
      "MI7TZZS-PGXBWLU-YIPVZ2T-EX4AR5F-LKCWYF7-CSZWHBD-JDPSKKI-RXRUXAX";

    # also the "syncthing" smb share
    settings.folders.sync = {
      id = "sync";
      path = "/srv/nas/syncthing/sync";
      devices = [ "luca-pc" "luca-notebook" ];
      type = "sendreceive";
      ignorePerms = true;
    };
  };



  # lsck0 pacman repo, built by vm-119; plain http, the packages and db are signed
  services.nginx = {
    enable = true;
    virtualHosts.archrepo = {
      listen = [{ addr = "0.0.0.0"; port = 8090; }];
      root = "/srv/nas/bulk/archrepo";
      extraConfig = ''
        autoindex on;
        # internal, lan, wireguard, tailnet
        allow 10.100.0.0/24;
        allow ${site.lan.subnet};
        allow 10.0.0.0/24;
        allow 100.64.0.0/10;
        deny all;
      '';
      # builder state, and the mirror's .~tmp~ staging dirs mid-sync
      locations."~ /\\.".return = "404";
      # full official mirror, same vhost, a distinct path: lsck0 stays at /x86_64 and keeps authority for
      # overridden/aur packages (clients list it first); official core/extra/multilib come from /archlinux.
      # symlinks stay enabled (the default): the package files are relative links into the shared pool/ and
      # --safe-links already bars any escape, so disable_symlinks on would 404 every package.
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

  # tokens moved from the one shared homepage-tokens dir into one dir per producer (modules/tokens.nix);
  # a token an app minted once (an admin password it was set up with) must move, a fresh one would not log in.
  # rename keeps mode and owner; what is left behind afterwards belongs to no registered producer.
  systemd.services.lab-tokens-migrate = {
    description = "Move tokens from the shared homepage-tokens dir into their producers' dirs";
    wantedBy = [ "multi-user.target" ];
    before = [ "nfs-server.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      old=/srv/nas/data/homepage-tokens
      [ -d "$old" ] || exit 0
      ${lib.concatStrings (lib.mapAttrsToList (name: id: ''
        if [ -e "$old/${name}.token" ] && [ ! -e /srv/nas/data/tokens/vm-${toString id}/${name}.token ]; then
          ${pkgs.coreutils}/bin/install -d -m 0777 /srv/nas/data/tokens/vm-${toString id}
          ${pkgs.coreutils}/bin/mv -n "$old/${name}.token" /srv/nas/data/tokens/vm-${toString id}/
          echo "moved ${name} to vm-${toString id}"
        fi
      '') config.homelab.tokens.producers)}
    '';
  };

  # hourly: official repos update a few times a day, so an hour caps the lag. idle i/o and lowest cpu
  # priority keep the sync behind live nfs serving and the nightly archbuild; flock drops an hourly tick
  # that lands while the slow first full sync is still running.
  systemd.services.archmirror-sync = {
    description = "Sync the full official Arch mirror (core/extra/multilib, x86_64) from a tier-1 upstream";
    after = [ "network-online.target" "srv-nas-bulk.mount" ];
    wants = [ "network-online.target" ];
    requires = [ "srv-nas-bulk.mount" ];
    startAt = "hourly";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/flock -n ${mirrorLock} ${mirrorSync}";
      IOSchedulingClass = "idle";
      Nice = 19;
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 2049 111 8090 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 2049 111 22000 21027 ];

  # authelia is the only gate for 80 and 8384
  homelab.ingressOnly.ports = [ 80 8384 ];

  # hot page cache is the point here (nfs serving, tsdb, streams)
  homelab.dropCaches = false;
}
