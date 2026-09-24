{ config, lib, utils, ... }:

let
  nasIP = "10.100.0.109";
  # read-write mounts are `hard`: a `soft` rw mount returns an I/O error to the
  # application after timeo and can silently corrupt or lose a write when the NAS
  # blips: including the Postgres data directories that live here. `hard` blocks
  # and retries instead. Read-only media mounts stay `soft`, where a failed read
  # is harmless and blocking is worse.
  nfsOpts = [ "nfsvers=4" "rw" "hard" "timeo=50" "x-systemd.automount" "x-systemd.idle-timeout=60" ];
  nfsOptsRo = [ "nfsvers=4" "ro" "soft" "timeo=15" "x-systemd.automount" "x-systemd.idle-timeout=60" ];

  # the only /srv/nas/data shares the DMZ may mount, per VM. vm-109 exports
  # exactly these to exactly that address, nothing else under the tree: a
  # compromised public VM has root on its own share and no other.
  dmzShares = {
    "200" = [ "crowdsec-external" "traefik-acme-external" ];
    "201" = [ "headscale" ];
    "202" = [ "tor-relay-keys" ];
    "204" = [ "searxng" ];
    "205" = [ "shlink" "homepage-tokens/external" ];
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

  # Anything stateful on an NFS mount is slow to shut down, and systemd's
  # default 45s stop timeout is not enough for it. When it expires the service
  # is SIGKILLed, lands in `failed`, and - because most upstream units do not
  # restart on failure - simply stays down. A deploy would take Postgres,
  # Prometheus or Grafana out on one VM after another and report success,
  # because the deploy itself worked; only the probes noticed, hours later.
  #
  # So: time to stop cleanly, and a restart if it still does not.
  # a DMZ mount missing from dmzShares would hang at boot on a denied export.
  assertions = lib.optionals external (map (d: {
    assertion = lib.elem d allowed;
    message = "${config.networking.hostName} mounts ${d}, which is not in dmzShares.\"${vmid}\" (modules/nas.nix)";
  }) nasDevices);

  systemd.services = {
    postgresql.serviceConfig = lib.mkIf (config.services.postgresql.enable or false) {
      TimeoutStopSec = "3min";
      Restart = lib.mkForce "on-failure";
      RestartSec = 10;
    };

    # systemd-tmpfiles skips paths below an automount that is not mounted yet,
    # so the boot-time run never creates directories inside the NAS shares.
    # Mount them, then apply the rules for those paths; retried until the NAS
    # answers.
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
  # a container that starts before its share is ready fails: keep retrying
  # instead of giving up after systemd's default five starts.
  // lib.genAttrs containerUnits (_: {
    startLimitIntervalSec = 0;
    serviceConfig.RestartSec = lib.mkDefault 10;
    # `before` alone does not stop a container starting with the share
    # unmounted, which makes podman bind the empty directory under the
    # automount and the app write a fresh database over it. The dependency is
    # on the .automount, not RequiresMountsFor: that forces the .mount up and
    # then one unhappy NFS share blocks every container.
    requires = nasAutomounts;
    after = nasAutomounts;
  });
}
