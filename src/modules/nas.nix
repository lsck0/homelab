{ config, lib, utils, inventory, ... }:

let
  nasIP = "10.100.0.109";
  # systemd refuses automounts inside a container, so lxc guests mount at boot
  container = config.boot.isContainer;
  # after a power loss the nas may still be booting: a mount waits for it instead of failing its dependents
  mountOpts = [ "retry=10" "x-systemd.mount-timeout=10min" ]
    ++ (if container then [ "_netdev" ] else [ "x-systemd.automount" "x-systemd.idle-timeout=60" ]);
  # hard: a nas outage blocks writers until it is back, it never corrupts them
  nfsOpts = [ "nfsvers=4" "rw" "hard" "timeo=50" ] ++ mountOpts;
  nfsOptsRo = [ "nfsvers=4" "ro" "soft" "timeo=15" ] ++ mountOpts;

  match = builtins.match "vm-([0-9]+)" config.networking.hostName;
  # the dmz and the apps zone: anything not internal gets per-service state only
  external = match != null && (inventory.${builtins.head match}.type or "internal") != "internal";

  nasFileSystems = lib.filterAttrs (_: fs: lib.hasPrefix "${nasIP}:" (fs.device or "")) config.fileSystems;
  nasMountpoints = lib.attrNames nasFileSystems;
  # podman-<name> or docker-<name>, whichever backend the host runs
  containerUnits = map (c: c.serviceName) (lib.attrValues config.virtualisation.oci-containers.containers);
  nasAutomounts = map (m: "${utils.escapeSystemdPath m}.${if container then "mount" else "automount"}") nasMountpoints;

  mount = options: mountpoint: path: {
    "${mountpoint}" = {
      device = "${nasIP}:/srv/nas/${path}";
      fsType = "nfs";
      inherit options;
    };
  };
in {
  options.homelab.nasShares = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        path = lib.mkOption { type = lib.types.str; };
        readOnly = lib.mkOption { type = lib.types.bool; };
      };
    });
    readOnly = true;
    description = "NAS paths this host mounts; vm-109 exports each one to this host only.";
  };

  config = {
    _module.args = {
      nasMount = mountpoint: name: mount nfsOpts mountpoint "data/${name}";
      # vm-109 exports it read-only to this host
      nasMountRo = mountpoint: name: mount nfsOptsRo mountpoint "data/${name}";
      nasMedia = mountpoint: subpath: mount nfsOptsRo mountpoint "bulk/media/${subpath}";
      nasPath = mount nfsOpts;
    };

    homelab.nasShares = lib.mapAttrsToList (_: fs: {
      path = lib.removePrefix "${nasIP}:" fs.device;
      readOnly = lib.elem "ro" fs.options;
    }) nasFileSystems;

    # the dmz reaches only per-service state, never media or documents
    assertions = lib.optionals external (map (s: {
      assertion = lib.hasPrefix "/srv/nas/data/" s.path;
      message = "${config.networking.hostName} mounts ${s.path}; dmz hosts may only mount /srv/nas/data/<share>";
    }) config.homelab.nasShares);

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
  };
}
