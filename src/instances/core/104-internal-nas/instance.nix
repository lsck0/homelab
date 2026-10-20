# storage: NFS + SMB + Syncthing + FileBrowser, Kopia backups of it
{
  lib,
  site,
  telemetry,
  profiles,
  ...
}:
{
  roles = [ "nas" ];

  vm = {
    bootPhase = "nas";
    needs = [
      "containers"
      "nfs"
    ];
    # at 1.5 GiB the nas oom-killed its own jobs; lib/nas-job.nix caps them from it: 2376 MiB peak over 35d
    memoryMiB = 2816;
    # nvme root: state, documents and the syncthing repository (lib/kopia.nix), which holds cold storage's snapshots
    # too: cold storage was 241 GB on 2026-10-19 and grows only, so the disk grows with it, on the ssd_root_full
    # warning, before kopia-syncthing stops at 85%. Thin on the host's pve pool: what the guest frees reaches the pool
    # with the daily trim. That pool is overcommitted (1716 GiB of volumes on 1.25 TiB, 2026-10-19), so the host's
    # thinpool_data alerts may fire before this disk fills: move kopia-syncthing to bulk or add a pv to pve, never grow
    # this disk then
    diskGiB = 750;
    # its root shares the nvme with every guest's: a nightly snapshot or mirror sync never saturates it
    diskLimits.writeMBps = 300;
    disks = lib.optional (site.bulk != null) {
      inherit (site.bulk) sizeGiB;
      store = "bulk";
    };
  };

  services =
    let
      on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed;
    in
    {
      kopia = {
        host = "backup";
        port = 51515;
        homepage = {
          group = "Core";
          icon = "kopia";
        };
        inherit on;
      };
      nas = {
        port = 80;
        homepage = {
          group = "Core";
          icon = "mdi-nas";
          name = "NAS";
        };
        # file uploads through filebrowser
        on = lib.remove "bodyLimit" on;
      };
      syncthing = {
        host = "sync";
        port = 8384;
        homepage = {
          group = "Core";
          icon = "syncthing";
        };
        inherit on;
      };
    };

  alerts =
    let
      # a nightly job's window: the night itself plus a late start
      nightlyStaleSeconds = 26 * 3600;
      # a failed night is tolerated (proton's api fails runs now and then), plus start jitter and run length
      offsiteStaleSeconds = 60 * 3600;
      # lib/kopia.nix uploads cold storage weekly (coldStorageUploadAt): a failed week, plus jitter and run length
      coldStorageOffsiteStaleSeconds = 15 * 24 * 3600;
      # its mirror label, kopia.nix coldStorageLabel
      coldStorageMirror = "\"cold-storage\"";
      # kopia.nix starts the first upload 15 min past a deploy and stops it after 12h: a day and a half to spare before
      # a cold storage never uploaded pages
      coldStorageFirstUploadGraceHours = 48;
      coldStorageStale = "time() - max(homelab_offsite_last_success_timestamp_seconds{mirror=${coldStorageMirror}}) > bool ${toString coldStorageOffsiteStaleSeconds}";
      # kopia.nix drops the success time while the upload marker is missing: 0 every hour of the grace
      coldStorageNeverUploaded = "sum_over_time((max(homelab_offsite_uploaded{mirror=${coldStorageMirror}}) == bool 0)[${toString coldStorageFirstUploadGraceHours}h:1h]) >= bool ${toString coldStorageFirstUploadGraceHours}";
      # kopia.nix rootUsedMaxPercent stops the syncthing repository's snapshots at 85%: this warns with room to act
      ssdRootWarnPercent = 75;
      # this guest's vm label (modules/telemetry.nix vmName)
      ssdRoot = "vm=\"nas\",mountpoint=\"/\"";
      # df's percentage, which that guard reads: the blocks reserved for root count as neither used nor free
      ssdRootUsed =
        let
          used = "(node_filesystem_size_bytes{${ssdRoot}} - node_filesystem_free_bytes{${ssdRoot}})";
        in
        "100 * ${used} / (${used} + node_filesystem_avail_bytes{${ssdRoot}})";
      # lib/kopia.nix verifies weekly (verifyAt): a missed week plus its randomized delay
      verifyStaleSeconds = 8 * 24 * 3600 + 3600;
      # a proton outage is its own "proton unavailable" alert, not a stale off-site copy too
      whileProtonUp = expr: "(${expr}) * on () ${telemetry.upstreamUp "proton"}";
    in
    {
      backup_stale = {
        title = "NAS snapshot stale";
        category = "backups";
        # the stalest source: the nas's (type daily), the syncthing folders' (type syncthing) and cold storage's
        expr = "time() - min(homelab_backup_last_success_timestamp_seconds)";
        threshold = nightlyStaleSeconds;
        # missing data alerts too, but only once prometheus had time to scrape after a boot
        for = "30m";
        noData = "Alerting";
        severity = "critical";
        telegram = true;
        summary = "NAS snapshot: a source has none in over 26h";
        description = "Kopia on vm-104 has not completed a snapshot of /srv/nas (type daily, `systemctl status kopia-server`), of /srv/nas/syncthing (type syncthing) or of /srv/nas/bulk/cold-storage (type cold-storage, both `journalctl -u kopia-syncthing`).";
      };
      offsite_stale = {
        title = "Off-site copy stale";
        category = "backups";
        # the stalest nightly or hourly mirror; the syncthing folder's reads 0 until its first success
        expr = whileProtonUp "time() - min(homelab_offsite_last_success_timestamp_seconds{mirror!=${coldStorageMirror}})";
        threshold = offsiteStaleSeconds;
        for = "30m";
        noData = "Alerting";
        severity = "critical";
        telegram = true;
        summary = "Off-site (Proton Drive): a mirror has not uploaded in over 60h";
        description = "proton-sync (kopia repository) or proton-bisync (syncthing folder, both ways) on vm-104 has not finished; a share mirror at 0 never synced (FEATURES.md, Storage, backups and off-site). Check `journalctl -u proton-sync -u proton-bisync` and the mirror label of homelab_offsite_last_success_timestamp_seconds; homelab_offsite_last_skip_timestamp_seconds is a bisync run skipped behind another nas job.";
      };
      cold_storage_offsite_stale = {
        title = "Cold storage off-site copy stale";
        category = "backups";
        # 1 when stale, or when never uploaded past the grace
        expr = whileProtonUp "${coldStorageStale} or on () ${coldStorageNeverUploaded}";
        threshold = 0;
        for = "30m";
        noData = "Alerting";
        severity = "critical";
        telegram = true;
        summary = "Off-site (Proton Drive): cold storage has not uploaded in over 15 days, or never in 2 days";
        description = "The weekly proton-cold-storage on vm-104 has not finished an upload of /srv/nas/bulk/cold-storage, or never ran (homelab_offsite_uploaded 0, no .uploaded marker in /var/lib/proton-drive). `journalctl -u proton-cold-storage`; a first upload cut short by its timeout resumes the next week.";
      };
      ssd_root_full = {
        title = "NAS ssd filling up";
        category = "storage";
        expr = ssdRootUsed;
        threshold = ssdRootWarnPercent;
        for = "30m";
        telegram = true;
        summary = "vm-104 /: {{ printf \"%.0f\" $values.A.Value }}% used; the syncthing snapshots stop at 85%";
        description = "The syncthing repository on vm-104's root (/srv/nas/BACKUPS/kopia-syncthing, cold storage's snapshots too) shares it with every service's state; past 85% kopia-syncthing refuses to snapshot. `du -xhd1 /srv/nas/BACKUPS`, then delete snapshots no longer needed (`kopia-syncthing snapshot list`) or grow the disk (instance.nix diskGiB).";
      };
      backup_verify_stale = {
        title = "NAS backup unverified";
        category = "backups";
        expr = "time() - max(homelab_backup_verify_last_success_timestamp_seconds)";
        threshold = verifyStaleSeconds;
        for = "30m";
        noData = "Alerting";
        severity = "critical";
        telegram = true;
        summary = "Kopia repository: no successful verify in over a week";
        description = "kopia-verify on vm-104 found unreadable or corrupt files, or did not run. `journalctl -u kopia-verify`.";
      };
      offsite_verify_stale = {
        title = "Off-site copy unverified";
        category = "backups";
        expr = whileProtonUp "time() - max(homelab_offsite_verify_last_success_timestamp_seconds)";
        threshold = verifyStaleSeconds;
        for = "30m";
        noData = "Alerting";
        severity = "critical";
        telegram = true;
        summary = "Off-site (Proton Drive): no sampled blob matched the local repository in over a week";
        description = "kopia-verify on vm-104 could not download a sample of the off-site blobs, or one differed. `journalctl -u kopia-verify`.";
      };
      media_quota = {
        title = "Media quota almost full";
        category = "storage";
        expr = "100 * max(homelab_media_bytes) / max(homelab_media_quota_bytes)";
        threshold = 95;
        for = "1h";
        summary = "media and torrents at {{ printf \"%.0f\" $values.A.Value }}% of their quota";
        description = "Downloads and imports stop at the quota (104-internal-nas main.nix mediaQuotaGiB). Let janitorr clean up, delete media, or raise the quota.";
      };
    };

  secrets = {
    kopia-password = "guardsData:hex:24"; # the backup repository's key, see FEATURES.md Recovery
    kopia-server-password = "hex:24"; # the web ui's basic auth, user kopia
    # the owner's cifs credentials file the desktops mount with; lib/samba.nix sets the samba password from it
    samba-homelab = "dotfiles:samba-homelab";
    # restoring the off-site backup signs in with them (FEATURES.md, Recovery); vm-104 reads neither, its cli keeps the
    # session of proton-drive-login
    proton-username = "public";
    proton-password = "manual";
  };
}
