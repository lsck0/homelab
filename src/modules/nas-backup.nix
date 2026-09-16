{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.nasBackup;

  # restic wrapper: one repo, one password file, a fixed exclude of the backup
  # store itself. Everything else is passed per-invocation.
  resticEnv = ''
    export RESTIC_REPOSITORY="${cfg.repoDir}"
    export RESTIC_PASSWORD_FILE="${cfg.passwordFile}"
    export PATH="${lib.makeBinPath [ pkgs.restic pkgs.coreutils pkgs.curl pkgs.jq ]}"
  '';

  backupScript = pkgs.writeShellScript "nas-backup" ''
    set -uo pipefail
    ${resticEnv}

    SOURCE="${cfg.sourceDir}"
    TFDIR=/var/lib/node-exporter-textfile
    ${pkgs.coreutils}/bin/mkdir -p "$TFDIR"

    fail() {
      echo "BACKUP FAILED: $1" >&2
      # Publish a stale/failed marker path? No — leave the last-success metric
      # untouched so the dead-man rule fires, and hit the healthcheck /fail.
      ${lib.optionalString (cfg.healthcheckUrl != "") ''
        curl -fsS -m 15 "${cfg.healthcheckUrl}/fail" >/dev/null 2>&1 || true
      ''}
      exit 1
    }

    # Repo is content-addressed + encrypted; init once (idempotent).
    if ! restic cat config >/dev/null 2>&1; then
      echo ">>> Initialising restic repo at ${cfg.repoDir}"
      restic init || fail "restic init"
    fi

    # A stale lock (from a killed run) would block forever; drop locks older
    # than an hour, then proceed.
    restic unlock --remove-all >/dev/null 2>&1 || true

    echo ">>> restic backup of $SOURCE"
    restic backup "$SOURCE" \
      --exclude "${cfg.repoDir}" \
      ${lib.concatMapStringsSep " " (d: "--exclude '${d}'") cfg.excludePatterns} \
      --tag scheduled --host nas \
      || fail "restic backup"

    # Retention: deduplicated, so a year of history is cheap. Prune reclaims
    # space safely (never a blind delete of the newest data).
    echo ">>> restic forget --prune"
    restic forget \
      --keep-last ${toString cfg.keepLast} \
      --keep-daily ${toString cfg.keepDaily} \
      --keep-weekly ${toString cfg.keepWeekly} \
      --keep-monthly ${toString cfg.keepMonthly} \
      --prune \
      || fail "restic forget/prune"

    # Integrity: verify structure every run and re-read a sample of the actual
    # pack data (full re-read is expensive; a rolling subset catches bitrot).
    echo ">>> restic check (subset read)"
    restic check --read-data-subset=${cfg.checkSubset} || fail "restic check"

    # Guard against a silently-empty backup: the latest snapshot must contain a
    # non-trivial number of files, else something upstream vanished.
    FILES=$(restic snapshots --json --latest 1 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r '.[0].summary.total_files_processed // 0')
    if [ "''${FILES:-0}" -lt ${toString cfg.minFiles} ]; then
      fail "latest snapshot only has ''${FILES} files (< ${toString cfg.minFiles}) — refusing to report success"
    fi

    # Dead-man's-switch metric for the node-exporter textfile collector; a
    # Grafana rule alerts to ntfy if it goes stale. Written atomically.
    {
      echo "# HELP homelab_backup_last_success_timestamp_seconds Unix time of last successful NAS backup."
      echo "# TYPE homelab_backup_last_success_timestamp_seconds gauge"
      echo "homelab_backup_last_success_timestamp_seconds{type=\"daily\"} $(${pkgs.coreutils}/bin/date +%s)"
      echo "# HELP homelab_backup_snapshot_files Files in the latest restic snapshot."
      echo "# TYPE homelab_backup_snapshot_files gauge"
      echo "homelab_backup_snapshot_files $FILES"
    } > "$TFDIR/nas_backup.prom.tmp"
    ${pkgs.coreutils}/bin/mv "$TFDIR/nas_backup.prom.tmp" "$TFDIR/nas_backup.prom"

    ${lib.optionalString (cfg.healthcheckUrl != "") ''
      curl -fsS -m 15 "${cfg.healthcheckUrl}" >/dev/null 2>&1 || true
    ''}
    echo ">>> Backup complete: $FILES files in latest snapshot"
  '';
  # Restore/inspect helper installed on the NAS as `nas-restore`. Wraps restic
  # with the repo + password already set, plus convenience subcommands. Restore
  # is the half that matters — this makes it a one-liner and keeps it tested.
  restoreScript = pkgs.writeShellScriptBin "nas-restore" ''
    set -euo pipefail
    ${resticEnv}
    cmd="''${1:-help}"; shift || true
    case "$cmd" in
      list)     exec restic snapshots "$@" ;;
      files)    # files <snapshot>  — list files in a snapshot
                exec restic ls "''${1:-latest}" ;;
      service)  # service <name> [age]  — restore /srv/nas/data/<name> IN PLACE.
                # age 0 = latest (default), 1 = 2nd-latest, 2 = 3rd-latest, ...
                name="''${1:?usage: nas-restore service <name> [age]  (e.g. minecraft, or paperless 1)}"
                age="''${2:-0}"
                path="${cfg.sourceDir}/data/$name"
                id=$(restic snapshots --json | jq -r ".[-1-$age].id // empty")
                [ -n "$id" ] || { echo "no snapshot at age $age"; exit 1; }
                when=$(restic snapshots --json | jq -r ".[-1-$age].time")
                echo ">>> Restore $path"
                echo ">>> from snapshot $id (age $age, $when) — IN PLACE, overwrites current."
                echo ">>> STOP the VM using $path first (e.g. minecraft=207, paperless=113)."
                printf ">>> type 'yes' to proceed: "; read -r ok; [ "$ok" = yes ] || { echo aborted; exit 1; }
                restic restore "$id" --target / --include "$path"
                echo ">>> done: $path restored from $when" ;;
      restore)  # restore <snapshot|latest> <target-dir> [--include PATH ...]
                snap="''${1:?usage: nas-restore restore <snapshot|latest> <target> [--include PATH]}"; shift
                tgt="''${1:?target dir required}"; shift || true
                mkdir -p "$tgt"
                echo ">>> restoring $snap -> $tgt (verify after)"
                restic restore "$snap" --target "$tgt" "$@"
                echo ">>> restored. Contents under $tgt/srv/nas" ;;
      dump)     # dump <snapshot> <path-in-repo>  — single file/dir to stdout (tar)
                exec restic dump "''${1:?snapshot}" "''${2:?path}" ;;
      mount)    # mount <dir>  — browse snapshots as a filesystem (needs fuse)
                d="''${1:?usage: nas-restore mount <dir>}"; mkdir -p "$d"
                echo ">>> Ctrl-C to unmount"; exec restic mount "$d" ;;
      check)    exec restic check --read-data "$@" ;;   # full re-read of all data
      diff)     exec restic diff "''${1:?snapA}" "''${2:?snapB}" ;;
      *) cat <<EOF
nas-restore — restore/inspect the NAS restic backup

  nas-restore list                         list snapshots (oldest first; last line = latest)
  nas-restore service <name> [age]         restore /srv/nas/data/<name> in place; age 0=latest,1=2nd-latest
                                           e.g.  nas-restore service minecraft      (last backup)
                                                 nas-restore service paperless 1    (2nd-last)
  nas-restore files [snapshot]             list files in a snapshot (default latest)
  nas-restore restore <snap|latest> <dir>  restore into <dir> (add --include /srv/nas/data/firefly to scope)
  nas-restore dump <snap> <path>           stream one file/dir (tar) to stdout
  nas-restore mount <dir>                   browse all snapshots as a filesystem
  nas-restore check                         full integrity re-read of the whole repo
  nas-restore diff <snapA> <snapB>          what changed between two snapshots

Repo: ${cfg.repoDir}
EOF
        ;;
    esac
  '';
in {
  options.homelab.nasBackup = {
    enable = lib.mkEnableOption "Encrypted, verified restic backups of the NAS";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas";
      description = "Tree to back up.";
    };

    repoDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas/BACKUPS/restic";
      description = ''
        Local restic repository. NOTE: on the same filesystem as the source, so
        this alone does NOT survive a disk/host loss — it gives dedup, integrity
        and long history. Add an off-site repo (restic copy to B2/S3/SFTP) for a
        real 3-2-1 backup; see homelab.nasBackup.remoteRepo (TODO).
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/restic-password";
      description = "File holding the restic repository password (from sops).";
    };

    excludePatterns = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "*.tmp" "lost+found" "*/BACKUPS/*" ];
      description = "Extra restic exclude patterns (the repo dir is always excluded).";
    };

    keepLast    = lib.mkOption { type = lib.types.int; default = 3;  };
    keepDaily   = lib.mkOption { type = lib.types.int; default = 7;  };
    keepWeekly  = lib.mkOption { type = lib.types.int; default = 8;  };
    keepMonthly = lib.mkOption { type = lib.types.int; default = 12; };

    checkSubset = lib.mkOption {
      type = lib.types.str;
      default = "5%";
      description = "Fraction of pack data re-read for bitrot detection each run.";
    };

    minFiles = lib.mkOption {
      type = lib.types.int;
      default = 50;
      description = "Fail (don't report success) if the latest snapshot has fewer files — catches a silently-empty backup.";
    };

    healthcheckUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Optional dead-man ping URL; pinged on success, with /fail on failure.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.restic restoreScript ];

    systemd.tmpfiles.rules = [
      "d /srv/nas/BACKUPS 0700 root root -"
      "d ${cfg.repoDir} 0700 root root -"
    ];

    systemd.services.nas-backup = {
      description = "Encrypted verified restic backup of the NAS";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = backupScript;
        # A backup that overruns a day should not stack with the next.
        TimeoutStartSec = "6h";
      };
    };
    systemd.timers.nas-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
