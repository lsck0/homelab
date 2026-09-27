{ config, lib, utils, ... }:

let
  nasIP = "10.100.0.109";
  # soft rw mounts surface i/o errors to apps
  nfsOpts = [ "nfsvers=4" "rw" "hard" "timeo=50" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  nfsOptsRo = [ "nfsvers=4" "ro" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];

  # the only shares the dmz may mount
  dmzShares = {
    "200" = [ "crowdsec-external" "traefik-acme-external" ];
    "204" = [ "searxng" ];
    "206" = [ "privatebin" ];
    "207" = [ "share" ];
    "208" = [ "minecraft" "minecraft-modpacks" ];
  };

  vmid = lib.removePrefix "vm-" config.networking.hostName;
  external = lib.hasPrefix "vm-2" config.networking.hostName;
  allowed = map (s: "${nasIP}:/srv/nas/data/${s}") (dmzShares.${vmid} or [ ]);

  nasFileSystems = lib.filterAttrs (_: fs: lib.hasPrefix "${nasIP}:" (fs.device or "")) config.fileSystems;
  nasDevices = lib.mapAttrsToList (_: fs: fs.device) nasFileSystems;
  nasMountpoints = lib.attrNames nasFileSystems;
  containerUnits = map (n: "podman-${n}") (lib.attrNames config.virtualisation.oci-containers.containers);
  nasAutomounts = map (m: "${utils.escapeSystemdPath m}.automount") nasMountpoints;
in {
  _module.args = {
    inherit dmzShares;

    nasMount = mountpoint: name: {
      "${mountpoint}" = {
        device = "${nasIP}:/srv/nas/data/${name}";
        fsType = "nfs";
        options = nfsOpts;
      };
    };

    nasMedia = mountpoint: subpath: {
      "${mountpoint}" = {
        device = "${nasIP}:/srv/nas/bulk/media/${subpath}";
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

  # dmz vms may only mount their own shares
  assertions = lib.optionals external (map (d: {
    assertion = lib.elem d allowed;
    message = "${config.networking.hostName} mounts ${d}, which is not in dmzShares.\"${vmid}\" (modules/nas.nix)";
  }) nasDevices);

  systemd.services = {
    # nfs postgres outlives the 45s stop default
    postgresql.serviceConfig = lib.mkIf (config.services.postgresql.enable or false) {
      TimeoutStopSec = "3min";
      Restart = lib.mkForce "on-failure";
      RestartSec = 10;
    };

    # tmpfiles skips unmounted automounts
    nas-tmpfiles = lib.mkIf (nasMountpoints != [ ]) {
      description = "Create tmpfiles directories inside the NAS mounts";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      before = map (u: "${u}.service") containerUnits;
      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 0;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; Restart = "on-failure"; RestartSec = 15; };
      script = ''
        for m in ${lib.escapeShellArgs nasMountpoints}; do
          ls "$m" >/dev/null
        done
        ${config.systemd.package}/bin/systemd-tmpfiles --create ${lib.concatMapStringsSep " " (m: "--prefix=${lib.escapeShellArg m}") nasMountpoints}
      '';
    };
  }
  # keep retrying containers until the share is up
  // lib.genAttrs containerUnits (_: {
    startLimitIntervalSec = 0;
    serviceConfig.RestartSec = lib.mkDefault 10;
    # before alone allows an unmounted start
    requires = nasAutomounts;
    after = nasAutomounts;
  });
}
