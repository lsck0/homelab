# storage: NFS + SMB + Syncthing + FileBrowser, Kopia backups of it
{ lib, site, ... }: {
  vm = {
    bootPhase = "nas";
    needs = [ "containers" "nfs" ];
    # kopia snapshots the whole nas, measured 624 MiB
    memoryMiB = 3072;
    balloonMiB = 2048;
    # nvme root: state, backups, documents
    diskGiB = 750;
    # media and torrents on the bulk hdd (site.json)
    disks = lib.optional (site.bulk != null) { sizeGiB = site.bulk.sizeGiB; store = "bulk"; };
  };

  services = {
    kopia = { host = "backup"; port = 51515; homepage = { group = "Core"; icon = "kopia"; }; };
    nas = {
      port = 80;
      homepage = { group = "Core"; icon = "mdi-nas"; name = "NAS"; };
      off = { bodyLimit = "file uploads through filebrowser"; };
    };
    syncthing = { host = "sync"; port = 8384; homepage = { group = "Core"; icon = "syncthing"; }; };
  };

  secrets = { kopia-password = "hex:24"; }; # the backup repository's key: never regenerate, see README restore
}
