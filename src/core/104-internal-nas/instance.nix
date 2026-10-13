# storage: NFS + SMB + Syncthing + FileBrowser, Kopia backups of it
{ lib, site, telemetry, profiles, ... }: {
  roles = [ "nas" ];

  vm = {
    bootPhase = "nas";
    needs = [ "containers" "nfs" ];
    # kopia snapshots the whole nas, measured 624 MiB; the rest above the floor is page cache for nfs
    memoryMiB = 3072;
    balloonMiB = 1536;
    # nvme root: state, backups, documents
    diskGiB = 750;
    # media and torrents on the bulk hdd (site.json)
    disks = lib.optional (site.bulk != null) { sizeGiB = site.bulk.sizeGiB; store = "bulk"; };
  };

  services = let on = profiles.hardenedInternal ++ profiles.listed ++ profiles.observed; in {
    kopia = { host = "backup"; port = 51515; homepage = { group = "Core"; icon = "kopia"; }; inherit on; };
    nas = {
      port = 80;
      homepage = { group = "Core"; icon = "mdi-nas"; name = "NAS"; };
      # file uploads through filebrowser
      on = lib.remove "bodyLimit" on;
    };
    syncthing = { host = "sync"; port = 8384; homepage = { group = "Core"; icon = "syncthing"; }; inherit on; };
  };

  alerts = let
    # a nightly job's window: the night itself plus a late start
    nightlyStaleSeconds = 26 * 3600;
    # a failed night is tolerated (proton's api fails runs now and then), plus start jitter and run length
    offsiteStaleSeconds = 60 * 3600;
    # lib/kopia.nix verifies weekly (verifyAt): a missed week plus its randomized delay
    verifyStaleSeconds = 8 * 24 * 3600 + 3600;
    # a proton outage is its own "proton unavailable" alert, not a stale off-site copy too
    whileProtonUp = expr: "(${expr}) * on () ${telemetry.upstreamUp "proton"}";
  in {
    backup_stale = {
      title = "NAS snapshot stale";
      category = "backups";
      expr = "time() - max(homelab_backup_last_success_timestamp_seconds{type=\"daily\"})";
      threshold = nightlyStaleSeconds;
      # missing data alerts too, but only once prometheus had time to scrape after a boot
      for = "30m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "NAS snapshot: none in over 26h";
      description = "Kopia on vm-104 has not completed a snapshot of /srv/nas. Check `systemctl status kopia-server`.";
    };
    offsite_stale = {
      title = "Off-site copy stale";
      category = "backups";
      # the stalest mirror (lib/kopia.nix): the repository's or the syncthing folder's sync, which reads 0 until its
      # first success (not signed in, no baseline)
      expr = whileProtonUp "time() - min(homelab_offsite_last_success_timestamp_seconds)";
      threshold = offsiteStaleSeconds;
      for = "30m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
      summary = "Off-site (Proton Drive): a mirror has not uploaded in over 60h";
      description = "proton-sync (kopia repository) or proton-bisync (syncthing folder, both ways) on vm-104 has not finished; a share mirror at 0 never synced (README.md, Off-site). Check `journalctl -u proton-sync -u proton-bisync` and the mirror label of homelab_offsite_last_success_timestamp_seconds.";
    };
    backup_verify_stale = {
      title = "NAS backup unverified";
      category = "backups";
      expr = "time() - max(homelab_backup_verify_last_success_timestamp_seconds)";
      threshold = verifyStaleSeconds;
      for = "30m";
      noData = "Alerting";
      severity = "critical"; telegram = true;
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
      severity = "critical"; telegram = true;
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
    kopia-password = "guardsData:hex:24"; # the backup repository's key, see README restore
    kopia-server-password = "hex:24"; # the web ui's basic auth, user kopia
    # the owner's cifs credentials file the desktops mount with; lib/samba.nix sets the samba password from it
    samba-homelab = "dotfiles:samba-homelab";
    # the proton account: restoring the off-site backup signs in with it (README, Recovery), with proton-totp-secret
    # of src/secrets/shared.sops.json; vm-104 reads neither, its cli keeps the session of proton-drive-login
    proton-username = "public";
    proton-password = "manual";
  };
}
