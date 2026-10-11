# state on the guest's own disk with a nas copy: sqlite over nfs corrupts or dies of SIGBUS (mmap), so the app runs
# on local files, `<name>-seed` reconciles them with the nas share data/<name> before every start of the app, and a
# nightly `<name>-mirror` copies them to the share
#
# Both copies carry a generation id (.generation). The seed fills a disk holding no file from the share, adopts local
# data when the share has no id yet (localState added to a service with data), and does nothing while the ids match.
# A share with an id the guest does not know was either restored (nas-restore writes a new id marked restored-): the
# seed then replaces the local copy with it and drops the mark; or it diverged (a lost local id, a second writer): the
# seed refuses and a human decides. One file, rewritten in place: the guest's nfs client revalidates an open file,
# but trusts a cached "no such file" for its attribute timeout. The mirror runs only while the ids match, so it never overwrites a restore; it
# starts `<name>-reseed` (a restart of the app, so the seed runs) when it finds one. Its share is marked localState
# (instance.nix `shares`), which tells nas-restore to write the ids and name the guest.
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
  # rsync's "some files vanished before they could be transferred": the app replaced a file (home assistant's
  # .storage/*.new renames) while the mirror copied the rest, which is complete
  rsyncVanishedStatus = 24;
  # nas-restore (109-internal-nas lib/kopia.nix) marks the generation it writes with this
  restoredPrefix = "restored-";
  excludes = s: lib.concatMapStringsSep " " (e: "--exclude ${lib.escapeShellArg e}") (s.exclude ++ [ generationFile ]);
  # mtimes to the nanosecond: whole seconds would skip a file rewritten at its size within the second of a copy, for good
  rsyncCopy = "rsync -a --delete --modify-window=-1";
  # a database and its journals, copied by the backup api instead; a sibling like gitea.db.before-<tag> is plain data
  sqliteFilesOf = glob: map (suffix: "${glob}${suffix}") [ "" "-wal" "-shm" "-journal" ];

  # the ids of both copies, empty where none is written
  generationsRead = local: nas: ''
    generation_of() { if [ -f "$1" ]; then cat "$1"; fi; }
    local_gen=$(generation_of ${local}/${generationFile})
    nas_gen=$(generation_of ${nas}/${generationFile})
  '';

  # the app's own user owns its state directory; a copy from the share must not hand it to the share's squashed owner
  ownerOf = s: let sc = config.systemd.services.${s.unit}.serviceConfig; user = sc.User or "root"; in
    "${user}:${sc.Group or user}";

  reconcile = name: s: let local = s.path; nas = nasDir name; in pkgs.writeShellScript "${name}-reconcile" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.rsync pkgs.findutils pkgs.coreutils pkgs.util-linux ]}
    mkdir -p ${local}
    # the nas share itself, still mounted from before localState: copying it onto itself would destroy it
    if mountpoint -q ${local}; then echo "${name}: ${local} is a mount, not the guest's disk; unmount it" >&2; exit 1; fi
    ${generationsRead local nas}
    # the local id first: a crash between the writes leaves the mark, and the next seed copies again
    from_nas() {
      mode=$(stat -c %a ${local})
      ${rsyncCopy} ${excludes s} ${nas}/ ${local}/
      # rsync gave the directory itself the share's owner and mode (root squashed to nobody)
      chown ${ownerOf s} ${local}
      chmod "$mode" ${local}
      printf '%s\n' "''${nas_gen#${restoredPrefix}}" > ${local}/${generationFile}
      printf '%s\n' "''${nas_gen#${restoredPrefix}}" > ${nas}/${generationFile}
    }
    if [ -n "$local_gen" ] && [ "$local_gen" = "$nas_gen" ]; then
      exit 0
    elif [ -z "$(find ${local} -type f ! -name ${generationFile} -print -quit)" ]; then
      if [ -z "$nas_gen" ]; then nas_gen=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$nas_gen" > ${nas}/${generationFile}; fi
      from_nas
      echo "${name}: seeded ${local} from the nas copy"
    elif [ -z "$nas_gen" ]; then
      if [ -z "$local_gen" ]; then local_gen=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$local_gen" > ${local}/${generationFile}; fi
      printf '%s\n' "$local_gen" > ${nas}/${generationFile}
      echo "${name}: the nas copy has no generation: keeping the local data, the next mirror replaces the nas copy"
    elif [ "$nas_gen" != "''${nas_gen#${restoredPrefix}}" ]; then
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
    homelab.textfiles = map (name: "local_state_${name}") (lib.attrNames cfg);
    homelab.nasMounts = lib.mkMerge (lib.mapAttrsToList (name: _:
      lib.mapAttrs (_: m: m // { localState = true; }) (nasMount (nasDir name) name)) cfg);

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
          ${generationsRead s.path (nasDir name)}
          if [ -z "$local_gen" ] || [ "$local_gen" != "$nas_gen" ]; then
            if [ "$nas_gen" != "''${nas_gen#${restoredPrefix}}" ]; then
              echo "${name}: the nas copy was restored, reseeding"
              exec systemctl start --no-block ${name}-reseed.service
            fi
            echo "${name}: generation ''${local_gen:-none} here, ''${nas_gen:-none} on the nas: not mirroring (${name}-seed says why)"
            exit 1
          fi
          status=0
          # the share's directory keeps its own mode: rsync would give it the local one
          share_mode=$(stat -c %a ${nasDir name})
          ${rsyncCopy} ${excludes s} ${lib.concatMapStringsSep " " (f: "--exclude ${lib.escapeShellArg f}") (lib.concatMap sqliteFilesOf s.sqlite)} ${s.path}/ ${nasDir name}/ \
            || status=$?
          chmod "$share_mode" ${nasDir name}
          if [ "$status" != 0 ] && [ "$status" != ${toString rsyncVanishedStatus} ]; then exit "$status"; fi
          for db in ${lib.concatMapStringsSep " " (g: "${s.path}/${g}") s.sqlite}; do
            [ -f "$db" ] || continue
            copy=${nasDir name}/''${db#${s.path}/}
            mkdir -p "$(dirname "$copy")"
            # a journal left from when the app ran on the share would be replayed into the fresh copy
            rm -f "$copy-wal" "$copy-shm" "$copy-journal"
            ${sqliteBackup.command "\"$db\"" "$copy"}
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
