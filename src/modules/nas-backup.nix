{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.nasBackup;

  backupScript = pkgs.writeShellScript "nas-backup" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.gnutar pkgs.zstd pkgs.findutils ]}"

    BACKUP_DIR="${cfg.backupDir}"
    SOURCE_DIR="${cfg.sourceDir}"
    TYPE="$1"  # daily, weekly, monthly

    mkdir -p "$BACKUP_DIR/$TYPE"

    STAMP=$(date +%Y-%m-%d_%H%M)
    DEST="$BACKUP_DIR/$TYPE/nas-$STAMP.tar.zst"

    echo ">>> Creating $TYPE backup: $DEST"
    tar --create --zstd \
      --exclude='*.tmp' \
      --exclude='lost+found' \
      -f "$DEST" \
      -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"

    echo ">>> Backup complete: $(du -sh "$DEST" | cut -f1)"

    # Rotate old backups
    KEEP="$2"
    cd "$BACKUP_DIR/$TYPE"
    ls -1t nas-*.tar.zst 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
      echo ">>> Removing old backup: $old"
      rm -f "$old"
    done
  '';
in {
  options.homelab.nasBackup = {
    enable = lib.mkEnableOption "Compressed NAS backups with rotation";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas";
      description = "Directory to back up.";
    };

    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/backups";
      description = "Where to store compressed backups.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0750 root root -"
      "d ${cfg.backupDir}/daily 0750 root root -"
      "d ${cfg.backupDir}/weekly 0750 root root -"
      "d ${cfg.backupDir}/monthly 0750 root root -"
    ];

    # Daily backup — keep 3 (start of day, 02:00)
    systemd.services.nas-backup-daily = {
      description = "Daily NAS backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript} daily 3";
      };
    };
    systemd.timers.nas-backup-daily = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 02:00:00";
        Persistent = true;
      };
    };

    # Weekly backup — keep 3 (start of week, Monday 03:00)
    systemd.services.nas-backup-weekly = {
      description = "Weekly NAS backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript} weekly 3";
      };
    };
    systemd.timers.nas-backup-weekly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Mon *-*-* 03:00:00";
        Persistent = true;
      };
    };

    # Monthly backup — keep 3 (1st of month, 04:00)
    systemd.services.nas-backup-monthly = {
      description = "Monthly NAS backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript} monthly 3";
      };
    };
    systemd.timers.nas-backup-monthly = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 04:00:00";
        Persistent = true;
      };
    };
  };
}
