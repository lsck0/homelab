{ ... }:

let
  nasIP = "10.100.0.108";
  # read-write mounts are `hard`: a `soft` rw mount returns an I/O error to the
  # application after timeo and can silently corrupt or lose a write when the NAS
  # blips: including the Postgres data directories that live here. `hard` blocks
  # and retries instead. Read-only media mounts stay `soft`, where a failed read
  # is harmless and blocking is worse.
  nfsOpts = [ "nfsvers=4" "rw" "hard" "timeo=50" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  nfsOptsRo = [ "nfsvers=4" "ro" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
in {
  _module.args = {
    nasMount = mountpoint: name: {
      "${mountpoint}" = {
        device = "${nasIP}:/srv/nas/data/${name}";
        fsType = "nfs";
        options = nfsOpts;
      };
    };

    nasMedia = mountpoint: subpath: {
      "${mountpoint}" = {
        device = "${nasIP}:/srv/nas/media/${subpath}";
        fsType = "nfs";
        options = nfsOptsRo;
      };
    };

    nasPath = mountpoint: naspath: {
      "${mountpoint}" = {
        device = "${nasIP}:/srv/nas/${naspath}";
        fsType = "nfs";
        options = nfsOpts;
      };
    };
  };
}
