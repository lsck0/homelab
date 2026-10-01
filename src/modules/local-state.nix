# state on the guest's own disk with a nas copy: sqlite over nfs corrupts or dies of SIGBUS (mmap),
# so the app runs on local files, a fresh disk is seeded from the nas, and a nightly mirror keeps the copy
{ config, lib, pkgs, nasMount, ... }:
let
  cfg = config.homelab.localState;

  stateType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Local state directory, e.g. /var/lib/jellyfin.";
      };
      share = lib.mkOption {
        type = lib.types.str;
        description = "NAS data share holding the copy, mounted at /srv/<name>-nas.";
      };
      unit = lib.mkOption {
        type = lib.types.str;
        description = "Service that must only start after the seed, e.g. podman-jellyfin.";
      };
      sqlite = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Globs, relative to path, of sqlite files: copied with .backup, never mid-write.";
      };
      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "cache" ];
        description = "Paths, relative to path, that are neither seeded nor mirrored.";
      };
    };
  };

  # daily, before the 01:30 db dumps and the 02:00 snapshot
  mirrorAt = "01:15";
  nasDir = name: "/srv/${name}-nas";
  excludes = s: lib.concatMapStringsSep " " (e: "--exclude ${lib.escapeShellArg e}") (s.exclude ++ [ ".seeded" ]);
in {
  options.homelab.localState = lib.mkOption {
    type = lib.types.attrsOf stateType;
    default = { };
    description = "Local state directories mirrored to the NAS, keyed by name.";
  };

  config = lib.mkIf (cfg != { }) {
    fileSystems = lib.mkMerge (lib.mapAttrsToList (name: s: nasMount (nasDir name) s.share) cfg);

    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: s: {
      # fresh disk: restore from the nas copy; a marker, not the dir, since tmpfiles creates the dir first
      "${name}-seed" = {
        before = [ "${s.unit}.service" ];
        requiredBy = [ "${s.unit}.service" ];
        unitConfig.RequiresMountsFor = [ (nasDir name) ];
        unitConfig.ConditionPathExists = "!${s.path}/.seeded";
        path = [ pkgs.rsync ];
        serviceConfig.Type = "oneshot";
        script = ''
          mkdir -p ${s.path}
          rsync -a --delete ${excludes s} ${nasDir name}/ ${s.path}/
          touch ${s.path}/.seeded
        '';
      };
      # restart so the seed runs before the app on the deploy that adds it
      "${s.unit}".restartTriggers = [ config.systemd.services."${name}-seed".script ];

      "${name}-mirror" = {
        startAt = mirrorAt;
        unitConfig.RequiresMountsFor = [ (nasDir name) ];
        # never mirror an unseeded install over the nas copy
        unitConfig.ConditionPathExists = "${s.path}/.seeded";
        path = [ pkgs.rsync pkgs.sqlite ];
        serviceConfig.Type = "oneshot";
        script = ''
          rsync -a --delete ${excludes s} ${lib.concatMapStringsSep " " (g: "--exclude ${lib.escapeShellArg "${g}*"}") s.sqlite} ${s.path}/ ${nasDir name}/
          cd ${s.path}
          for db in ${lib.concatStringsSep " " s.sqlite}; do
            [ -f "$db" ] || continue
            mkdir -p "${nasDir name}/$(dirname "$db")"
            sqlite3 "$db" ".backup '${nasDir name}/$db'"
          done
          # grafana's state_mirror_stale alert watches this
          d=/var/lib/node-exporter-textfile
          printf '# TYPE homelab_local_state_mirror_last_success_timestamp_seconds gauge\nhomelab_local_state_mirror_last_success_timestamp_seconds{state="%s"} %s\n' ${name} "$(date +%s)" > $d/local_state_${name}.prom.tmp
          mv $d/local_state_${name}.prom.tmp $d/local_state_${name}.prom
        '';
      };
    }) cfg);

    # an on-demand guest is rarely up at mirrorAt; catch up on the next boot
    systemd.timers = lib.mapAttrs' (name: _: lib.nameValuePair "${name}-mirror" {
      timerConfig.Persistent = true;
    }) cfg;
  };
}
