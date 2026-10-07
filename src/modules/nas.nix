# a guest's nas mounts: the helpers (nasMount, nasMountRo, nasMedia, nasPath), its fileSystems and the shares vm-109 exports
{ config, lib, utils, inventory, lab, ... }:
let
  nasIP = inventory.${lab.roles.nas}.ip;
  # systemd refuses automounts inside a container, so lxc guests mount at boot
  container = config.boot.isContainer;
  # after a power loss the nas may still be booting: a mount waits for it instead of failing its dependents
  mountOpts = [ "retry=10" "x-systemd.mount-timeout=10min" ]
    ++ (if container then [ "_netdev" ] else [ "x-systemd.automount" "x-systemd.idle-timeout=60" ]);
  # hard: a nas outage blocks writers until it is back, it never corrupts them
  nfsOpts = [ "nfsvers=4" "rw" "hard" "timeo=50" ] ++ mountOpts;
  nfsOptsRo = [ "nfsvers=4" "ro" "soft" "timeo=15" ] ++ mountOpts;

  vmid = config.homelab.vmid;
  # the dmz and the apps zone: anything not internal gets per-service state only
  external = vmid != null && (inventory.${vmid}.type or "internal") != "internal";

  nasMountpoints = lib.attrNames config.homelab.nasMounts;
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
  # a vm test replaces fileSystems wholesale (virtualisation.fileSystems), and nasShares derived back from
  # fileSystems would recurse: the mounts live in their own option, which fileSystems and the tests both read
  options.homelab.nasMounts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        device = lib.mkOption { type = lib.types.str; };
        fsType = lib.mkOption { type = lib.types.str; };
        options = lib.mkOption { type = lib.types.listOf lib.types.str; };
        shareMode = lib.mkOption {
          type = lib.types.nullOr (lib.types.strMatching "0[0-7]{3}");
          default = null;
          description = ''
            Mode of the shared directory on the NAS, owned by root: for a share only root writes (no_root_squash
            carries the guest's root through), so neither another uid of the guest nor the NAS's own smb guest and
            filebrowser can. null: 0777, any uid may write, for services that run as their own user.
          '';
        };
      };
    });
    default = { };
    description = ''
      NAS mounts of this host by mountpoint, written with the nasMount, nasMountRo, nasMedia and nasPath helpers:
      `homelab.nasMounts = nasMount "/var/lib/app" "app";`. They become fileSystems, homelab.nasShares and so
      vm-109's exports and the router's nfs rules.
    '';
  };

  options.homelab.nasFileSystems = lib.mkOption {
    type = lib.types.attrsOf lib.types.attrs;
    readOnly = true;
    internal = true;
    description = "homelab.nasMounts as fileSystems entries: what fileSystems, and a vm test's virtualisation.fileSystems, take.";
  };

  options.homelab.nasShares = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        path = lib.mkOption { type = lib.types.str; };
        readOnly = lib.mkOption { type = lib.types.bool; };
        mode = lib.mkOption { type = lib.types.nullOr lib.types.str; };
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

    homelab.nasFileSystems = lib.mapAttrs (_: m: { inherit (m) device fsType options; }) config.homelab.nasMounts;
    fileSystems = config.homelab.nasFileSystems;

    homelab.nasShares = lib.mapAttrsToList (_: fs: {
      path = lib.removePrefix "${nasIP}:" fs.device;
      readOnly = lib.elem "ro" fs.options;
      mode = fs.shareMode;
    }) config.homelab.nasMounts;

    # the dmz reaches only per-service state, never media or documents
    assertions = lib.optionals external (map (s: {
      assertion = lib.hasPrefix "/srv/nas/data/" s.path;
      message = "${config.networking.hostName} mounts ${s.path}; dmz hosts may only mount /srv/nas/data/<share>";
    }) config.homelab.nasShares);

    systemd.services = {
      # nfs postgres outlives the 45s stop default
      postgresql.serviceConfig = lib.mkIf config.services.postgresql.enable {
        TimeoutStopSec = "3min";
        Restart = lib.mkForce "on-failure";
        RestartSec = 10;
      };

      # a deploy that drops a mount leaves its automount active without a unit: autofs stays on the mountpoint
      # and every access fails with "host is down" until a reboot. Stop those, and nas mounts left without a unit
      nas-mounts-prune = {
        description = "Stop NAS mounts this configuration no longer declares";
        wantedBy = [ "multi-user.target" ];
        before = [ "nas-tmpfiles.service" ];
        restartTriggers = [ (builtins.toJSON nasMountpoints) ];
        path = [ config.systemd.package ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          systemctl list-units --all --plain --no-legend --type=automount,mount | while read -r unit _; do
            [ "$(systemctl show -P LoadState "$unit")" = not-found ] || continue
            case "$unit" in
              *.mount) case "$(systemctl show -P What "$unit")" in ${nasIP}:*) ;; *) continue ;; esac ;;
            esac
            echo "stopping $unit ($(systemctl show -P Where "$unit")), no longer declared"
            systemctl stop "$unit"
          done
        '';
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
