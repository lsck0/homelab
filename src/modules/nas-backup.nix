{ config, lib, pkgs, ... }:
let
  cfg = config.homelab.nasBackup;

  backupScript = pkgs.writeShellScript "nas-backup" ''
    set -uo pipefail
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.gnutar pkgs.zstd pkgs.findutils pkgs.rsync pkgs.openssh ]}"

    TYPE="$1"
    KEEP="$2"

    BACKUP_ROOT="${cfg.backupDir}"
    SOURCE="${cfg.sourceDir}"
    STAMP=$(date +%Y-%m-%d_%H%M)
    DEST="$BACKUP_ROOT/$TYPE/$STAMP"
    mkdir -p "$DEST"

    echo ">>> NAS $TYPE backup -> $DEST"
    FAILED=0

    backup_folder() {
      local src="$1" label="$2"
      [ -d "$src" ] || return 0
      local out="$DEST/$label.tar.zst"
      echo "  $src -> $label.tar.zst"
      tar --create --use-compress-program="${pkgs.zstd}/bin/zstd -T0 -19" \
        --ignore-failed-read --warning=no-file-changed \
        --exclude='*.tmp' --exclude='lost+found' \
        -f "$out" -C "$(dirname "$src")" "$(basename "$src")" || {
        echo "  WARNING: $label backup had errors (partial archive kept)"
        FAILED=1
      }
    }

    for dir in "$SOURCE"/*/; do
      name=$(basename "$dir")
      case "$name" in
        BACKUPS) ;;  # skip — this is the backup destination, not a source
        data)
          for sub in "$dir"*/; do
            [ -d "$sub" ] || continue
            backup_folder "$sub" "data-$(basename "$sub")"
          done
          ;;
        *)
          backup_folder "$dir" "$name"
          ;;
      esac
    done

    echo ">>> On-disk backup complete: $(du -sh "$DEST" | cut -f1)${if cfg.proxmoxBackupHost != null then "" else ""}"
    [ "$FAILED" -eq 0 ] || echo "WARNING: Some archives had read errors (partial data backed up)"

    # Rotate on-disk snapshots
    cd "$BACKUP_ROOT/$TYPE"
    ls -1dt */ 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
      echo ">>> Removing old snapshot: $old"
      rm -rf "$old"
    done

    # Sync latest snapshot to Proxmox host as off-disk copy
    ${lib.optionalString (cfg.proxmoxBackupHost != null) ''
      REMOTE="${cfg.proxmoxBackupHost}"
      REMOTE_DIR="${cfg.proxmoxBackupPath}/$TYPE/$STAMP"
      echo ">>> Syncing to Proxmox host $REMOTE:$REMOTE_DIR ..."
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -i /etc/nas-backup-key \
        "root@$REMOTE" "mkdir -p $REMOTE_DIR" 2>/dev/null \
        && rsync -a --delete \
          -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i /etc/nas-backup-key" \
          "$DEST/" "root@$REMOTE:$REMOTE_DIR/" \
        && echo ">>> Remote sync complete" \
        || echo "WARNING: Remote sync failed (local backup still intact)"

      # Rotate remote snapshots
      ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        -i /etc/nas-backup-key "root@$REMOTE" \
        "cd ${cfg.proxmoxBackupPath}/$TYPE && ls -1dt */ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf" \
        2>/dev/null || true
    ''}

    # Dead-man's-switch: ping on success, /fail on any archive error.
    ${lib.optionalString (cfg.healthcheckUrl != "") ''
      if [ "$FAILED" -eq 0 ]; then
        ${pkgs.curl}/bin/curl -fsS -m 15 "${cfg.healthcheckUrl}" >/dev/null 2>&1 || true
      else
        ${pkgs.curl}/bin/curl -fsS -m 15 "${cfg.healthcheckUrl}/fail" >/dev/null 2>&1 || true
      fi
    ''}
  '';
in {
  options.homelab.nasBackup = {
    enable = lib.mkEnableOption "Per-folder NAS backups with rotation";

    sourceDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas";
    };

    backupDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/nas/BACKUPS";
    };

    proxmoxBackupHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Proxmox host IP to rsync backups to as secondary copy.";
    };

    proxmoxBackupPath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/vz/nas-backups";
      description = "Path on Proxmox host for off-disk backup copies.";
    };

    healthcheckUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Dead-man's-switch ping URL (healthchecks.io or self-hosted). Pinged on a
        successful backup, and with /fail appended on failure. If nothing pings
        it within the grace window the watcher alerts, so a backup box that dies
        silently is caught. Empty disables it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Backup dirs are inside the NAS share — created here for idempotency.
    # BACKUPS/ itself is excluded from the backup source to prevent circular archiving.
    systemd.tmpfiles.rules = [
      "d ${cfg.backupDir} 0755 root root -"
      "d ${cfg.backupDir}/daily 0755 root root -"
      "d ${cfg.backupDir}/weekly 0755 root root -"
      "d ${cfg.backupDir}/monthly 0755 root root -"
    ];

    systemd.services.nas-backup-daily = {
      description = "Daily per-folder NAS backup";
      serviceConfig = { Type = "oneshot"; ExecStart = "${backupScript} daily 3"; };  # keep 3 days
    };
    systemd.timers.nas-backup-daily = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*-*-* 00:00:00"; Persistent = true; };
    };

    systemd.services.nas-backup-weekly = {
      description = "Weekly per-folder NAS backup";
      serviceConfig = { Type = "oneshot"; ExecStart = "${backupScript} weekly 2"; };  # keep 2 weeks
    };
    systemd.timers.nas-backup-weekly = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "Mon *-*-* 00:00:00"; Persistent = true; };
    };

    systemd.services.nas-backup-monthly = {
      description = "Monthly per-folder NAS backup";
      serviceConfig = { Type = "oneshot"; ExecStart = "${backupScript} monthly 1"; };  # keep 1 month
    };
    systemd.timers.nas-backup-monthly = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnCalendar = "*-*-01 00:00:00"; Persistent = true; };
    };
  };
}
