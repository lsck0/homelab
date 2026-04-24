{ lib, ... }:

let
  nasIP = "10.100.0.105";
  nfsOpts = [ "nfsvers=4" "rw" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
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
