# state on the guest's own disk with a nas copy: sqlite over nfs corrupts or dies of SIGBUS (mmap), so the app runs
# on local files, `<name>-seed` reconciles them with the nas share data/<name> before every start of the app, and a
# nightly `<name>-mirror` copies them to the share
#
# Both copies carry a generation id (.generation). The seed fills a disk holding no file from the share, adopts local
# data when the share has no id yet (localState added to a service with data), and does nothing while the ids match.
# A share with an id the guest does not know was either restored (nas-restore writes a new id, and the same id into
# .restored): the seed then replaces the local copy with it; or it diverged (a lost local id, a second writer): the
# seed refuses and a human decides. The mirror runs only while the ids match, so it never overwrites a restore; it
# starts `<name>-reseed` (a restart of the app, so the seed runs) when it finds one.
{ config, lib, pkgs, nasMount, ... }:
let
  cfg = config.homelab.localState;

  stateType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = "Local state directory, e.g. /var/lib/jellyfin.";
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

  sqliteBackup = import ../sqlite-backup.nix;
  # daily, before the 01:30 db dumps and the 02:00 snapshot
  mirrorAt = "01:15";
  nasDir = name: "/srv/${name}-nas";
  generationFile = ".generation";
  # nas-restore (109-internal-nas lib/kopia.nix) writes the generation it made here
  restoredFile = ".restored";
  excludes = s: lib.concatMapStringsSep " " (e: "--exclude ${lib.escapeShellArg e}") (s.exclude ++ [ generationFile restoredFile ]);

  reconcile = name: s: let local = s.path; nas = nasDir name; in pkgs.writeShellScript "${name}-reconcile" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.rsync pkgs.findutils pkgs.coreutils pkgs.util-linux ]}
    mkdir -p ${local}
    # the nas share itself, still mounted from before localState: copying it onto itself would destroy it
    if mountpoint -q ${local}; then echo "${name}: ${local} is a mount, not the guest's disk; unmount it" >&2; exit 1; fi
    nas_gen=$(cat ${nas}/${generationFile} 2>/dev/null || true)
    local_gen=$(cat ${local}/${generationFile} 2>/dev/null || true)
    restored=$(cat ${nas}/${restoredFile} 2>/dev/null || true)
    from_nas() {
      rsync -a --delete ${excludes s} ${nas}/ ${local}/
      printf '%s\n' "$nas_gen" > ${local}/${generationFile}
      rm -f ${nas}/${restoredFile}
    }
    if [ -n "$local_gen" ] && [ "$local_gen" = "$nas_gen" ]; then
      exit 0
    elif [ -z "$(find ${local} -type f ! -name ${generationFile} -print -quit)" ]; then
      [ -n "$nas_gen" ] || { nas_gen=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$nas_gen" > ${nas}/${generationFile}; }
      from_nas
      echo "${name}: seeded ${local} from the nas copy"
    elif [ -z "$nas_gen" ]; then
      [ -n "$local_gen" ] || { local_gen=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$local_gen" > ${local}/${generationFile}; }
      printf '%s\n' "$local_gen" > ${nas}/${generationFile}
      echo "${name}: the nas copy has no generation: keeping the local data, the next mirror replaces the nas copy"
    elif [ -n "$local_gen" ] && [ "$restored" = "$nas_gen" ]; then
      from_nas
      echo "${name}: replaced ${local} with the restored nas copy"
    else
      echo "${name}: ${local} (generation ''${local_gen:-none}) and the nas copy (generation $nas_gen) diverged."
      echo "  Keep the nas copy: empty ${local}, then systemctl start ${name}-reseed."
      echo "  Keep the local data: cp ${nas}/${generationFile} ${local}/; the next mirror replaces the nas copy."
      exit 1
    fi
  '';
in {
  options.homelab.localState = lib.mkOption {
    type = lib.types.attrsOf stateType;
    default = { };
    description = "Local state directories mirrored to the NAS share data/<name>, keyed by name.";
  };

  config = lib.mkIf (cfg != { }) {
    homelab.nasMounts = lib.mkMerge (lib.mapAttrsToList (name: _: nasMount (nasDir name) name) cfg);

    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: s: {
      # no RemainAfterExit: every start of the app runs it again
      "${name}-seed" = {
        before = [ "${s.unit}.service" ];
        requiredBy = [ "${s.unit}.service" ];
        unitConfig.RequiresMountsFor = [ (nasDir name) ];
        serviceConfig = { Type = "oneshot"; ExecStart = reconcile name s; };
      };
      # restart so the seed runs before the app on the deploy that changes it
      "${s.unit}".restartTriggers = [ (reconcile name s) ];

      "${name}-reseed" = {
        description = "Restart ${s.unit} so ${name}-seed takes a restored nas copy";
        serviceConfig = { Type = "oneshot"; ExecStart = "${config.systemd.package}/bin/systemctl restart ${s.unit}.service"; };
      };

      "${name}-mirror" = {
        startAt = mirrorAt;
        unitConfig.RequiresMountsFor = [ (nasDir name) ];
        path = [ pkgs.rsync pkgs.sqlite config.systemd.package ];
        serviceConfig.Type = "oneshot";
        script = ''
          local_gen=$(cat ${s.path}/${generationFile} 2>/dev/null || true)
          nas_gen=$(cat ${nasDir name}/${generationFile} 2>/dev/null || true)
          if [ -z "$local_gen" ] || [ "$local_gen" != "$nas_gen" ]; then
            if [ -n "$nas_gen" ] && [ "$(cat ${nasDir name}/${restoredFile} 2>/dev/null)" = "$nas_gen" ]; then
              echo "${name}: the nas copy was restored, reseeding"
              exec systemctl start --no-block ${name}-reseed.service
            fi
            echo "${name}: generation ''${local_gen:-none} here, ''${nas_gen:-none} on the nas: not mirroring (${name}-seed says why)"
            exit 1
          fi
          rsync -a --delete ${excludes s} ${lib.concatMapStringsSep " " (g: "--exclude ${lib.escapeShellArg "${g}*"}") s.sqlite} ${s.path}/ ${nasDir name}/
          cd ${s.path} || exit 1
          for db in ${lib.concatStringsSep " " s.sqlite}; do
            [ -f "$db" ] || continue
            mkdir -p "${nasDir name}/$(dirname "$db")"
            ${sqliteBackup.command "\"$db\"" "${nasDir name}/$db"}
          done
          # grafana's state_mirror_stale alert watches this
          d=${config.homelab.textfileDir}
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
