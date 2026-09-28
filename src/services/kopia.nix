# kopia: snapshots the nas it runs on, mirrors backups off-site to proton drive
{ config, lib, pkgs, ... }:
let
  source = "/srv/nas";
  repo = "/srv/nas/BACKUPS/kopia";
  configFile = "/var/lib/kopia/repository.config";

  kopiaEnv = ''
    export KOPIA_CONFIG_PATH=${configFile}
    export KOPIA_PASSWORD="$(cat ${config.sops.secrets.kopia-password.path})"
    export KOPIA_CHECK_FOR_UPDATES=false
    export KOPIA_LOG_DIR=/var/log/kopia
    export KOPIA_CACHE_DIRECTORY=/var/cache/kopia
    export PATH="${lib.makeBinPath [ pkgs.kopia pkgs.jq pkgs.coreutils pkgs.curl pkgs.systemd ]}:$PATH"
  '';

  # `kopia` pre-connected, for humans and hermes
  kopiaWrapper = pkgs.writeShellScriptBin "kopia-nas" ''
    ${kopiaEnv}
    exec kopia "$@"
  '';

  # restore helper, --yes lets hermes drive it
  restoreScript = pkgs.writeShellScriptBin "nas-restore" ''
    set -euo pipefail
    ${kopiaEnv}
    cmd="''${1:-help}"; shift || true
    export TZ=Europe/Berlin TZDIR=''${TZDIR:-/etc/zoneinfo}
    snapshots() { kopia snapshot list ${source} --json; }
    # ages shift with new snapshots, ids and dates do not
    pick() {
      case "$1" in
        [0-9]|[0-9][0-9]) snapshots | jq -c ".[-1-$1] // empty" ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9])
          snapshots | jq -c --arg d "$1" '[.[] | select(.startTime | sub("\\.[0-9]+"; "") | fromdateiso8601
            | localtime | strftime("%Y-%m-%d") == $d)] | last // empty' ;;
        *) snapshots | jq -c --arg id "$1" 'first(.[] | select(.id | startswith($id))) // empty' ;;
      esac
    }
    case "$cmd" in
      list)    snapshots | jq -r '.[] | "\(.id)  \(.startTime | sub("\\.[0-9]+"; "") | fromdateiso8601 | localtime | strftime("%Y-%m-%d %H:%M %Z"))  files:\(.rootEntry.summ.files)"' ;;
      files)   # files [snapshot] [subpath]
               sel="''${1:-0}"; sub="''${2:-}"
               id=$(pick "$sel" | jq -r '.rootEntry.obj // empty')
               [ -n "$id" ] || { echo "no snapshot matches $sel"; exit 1; }
               kopia ls -l "$id/$sub" ;;
      service) # service <name> [snapshot] [--yes], restore /srv/nas/data/<name> in place
               name="''${1:?usage: nas-restore service <name> [age|snapshot-id|YYYY-MM-DD] [--yes]}"
               sel="''${2:-0}"; yes="''${3:-}"
               [ "$sel" = "--yes" ] && { sel=0; yes=--yes; }
               snap=$(pick "$sel")
               [ -n "$snap" ] || { echo "no snapshot matches $sel"; exit 1; }
               obj=$(echo "$snap" | jq -r .rootEntry.obj)
               when=$(date -d "$(echo "$snap" | jq -r .startTime)" '+%F %T %Z')
               echo ">>> Restore ${source}/data/$name from snapshot $(echo "$snap" | jq -r .id) of $when, IN PLACE."
               echo ">>> Stop the service that uses it first (see src/instances.tf)."
               if [ "$yes" != "--yes" ]; then
                 printf ">>> type 'yes' to proceed: "; read -r ok; [ "$ok" = yes ] || { echo aborted; exit 1; }
               fi
               kopia restore "$obj/data/$name" "${source}/data/$name" \
                 --overwrite-files --overwrite-directories --overwrite-symlinks --no-ignore-permission-errors
               echo ">>> done: ${source}/data/$name restored from $when" ;;
      restore) # restore <snapshot> <subpath> <target-dir>
               sel="''${1:?snapshot}"; sub="''${2:?subpath under ${source}}"; tgt="''${3:?target dir}"
               obj=$(pick "$sel" | jq -r '.rootEntry.obj // empty')
               [ -n "$obj" ] || { echo "no snapshot matches $sel"; exit 1; }
               mkdir -p "$tgt"
               kopia restore "$obj/$sub" "$tgt" ;;
      now)     kopia snapshot create ${source} ;;
      verify)  kopia snapshot verify --verify-files-percent=5 ;;
      *) cat <<EOF
nas-restore: restore/inspect the NAS Kopia backups (UI: https://backup.lsck0.dev)

  <snapshot> is an id (from list), a date YYYY-MM-DD (newest snapshot of that
  local day) or an age (0 = newest; ages shift when a snapshot is taken).

  nas-restore list                              id, local time, file count (oldest first)
  nas-restore service <name> [snapshot] [--yes] restore /srv/nas/data/<name> in place
                                                e.g.  nas-restore service minecraft
                                                      nas-restore service paperless 2026-09-15 --yes
  nas-restore files [snapshot] [subpath]        list files in a snapshot
  nas-restore restore <snapshot> <subpath> <dir> restore a subtree into <dir>
  nas-restore now                          take a snapshot now
  nas-restore verify                       re-read 5% of the stored files

Raw kopia with the repository connected: kopia-nas <args>
Repo: ${repo}
EOF
      ;;
    esac
  '';
in {
  # old restic secret, renamed
  sops.secrets.kopia-password.key = "restic-password";

  environment.systemPackages = [ kopiaWrapper restoreScript ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kopia 0700 root root -"
    "d /var/log/kopia 0700 root root -"
    "d /var/cache/kopia 0700 root root -"
  ];

  # connect or create the repo, pin policy
  systemd.services.kopia-init = {
    description = "Connect Kopia repository and apply backup policy";
    after = [ "local-fs.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      ${kopiaEnv}
      mkdir -p ${repo}
      if ! kopia repository status >/dev/null 2>&1; then
        kopia repository connect filesystem --path=${repo} --override-hostname=nas --override-username=root \
          || kopia repository create filesystem --path=${repo} --override-hostname=nas --override-username=root
      fi
      # 02:00 daily, keep 7d / 8w / 12m
      kopia policy set ${source} \
        --snapshot-time=02:00 \
        --compression=zstd \
        --keep-latest=3 --keep-hourly=0 --keep-daily=7 --keep-weekly=8 --keep-monthly=12 --keep-annual=2 \
        --add-ignore=/BACKUPS --add-ignore=lost+found --add-ignore='*.tmp' \
        --add-ignore=/bulk --add-ignore=/data/qbittorrent-incomplete \
        --add-ignore=/documents/archive \
        --one-file-system=false
    '';
  };

  # server and web ui
  systemd.services.kopia-server = {
    description = "Kopia server and web UI";
    after = [ "kopia-init.service" ];
    requires = [ "kopia-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Restart = "always"; RestartSec = 10; };
    script = ''
      ${kopiaEnv}
      exec kopia server start --ui --insecure --without-password \
        --address=http://0.0.0.0:51515
    '';
  };

  # dead-man metric for the "backup stale" alert
  systemd.services.kopia-metrics = {
    description = "Publish Kopia snapshot freshness";
    after = [ "kopia-init.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${kopiaEnv}
      latest=$(kopia snapshot list ${source} --json | jq -r '.[-1] // empty')
      [ -n "$latest" ] || exit 0
      end=$(date -d "$(echo "$latest" | jq -r .endTime)" +%s)
      files=$(echo "$latest" | jq -r '.rootEntry.summ.files // 0')
      d=/var/lib/node-exporter-textfile; mkdir -p $d
      {
        echo "# HELP homelab_backup_last_success_timestamp_seconds Unix time of the newest NAS snapshot."
        echo "# TYPE homelab_backup_last_success_timestamp_seconds gauge"
        echo "homelab_backup_last_success_timestamp_seconds{type=\"daily\"} $end"
        echo "# HELP homelab_backup_snapshot_files Files in the newest NAS snapshot."
        echo "# TYPE homelab_backup_snapshot_files gauge"
        echo "homelab_backup_snapshot_files $files"
      } > $d/nas_backup.prom.tmp
      mv $d/nas_backup.prom.tmp $d/nas_backup.prom
    '';
  };
  systemd.timers.kopia-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10m"; OnUnitActiveSec = "15m"; };
  };

  # --without-password, authelia gates traefik
  networking.firewall.allowedTCPPorts = [ 51515 ];
  homelab.ingressOnly.ports = [ 51515 ];

  # ─────────────────────────────────────────────────────────────────────────────
  # OFF-SITE: PROTON DRIVE (repo shares the data's disk)
  sops.secrets.proton-username = {};
  sops.secrets.proton-password = {};
  # totp seed, not a code; rclone derives codes
  sops.secrets.proton-totp-secret = {};

  systemd.services.proton-sync = {
    description = "Mirror the NAS, all but bulk, to Proton Drive";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # proton throttles, first run uploads everything
      TimeoutStartSec = "12h";
    };
    path = [ pkgs.rclone pkgs.coreutils ];
    script = ''
      set -euo pipefail
      conf=/var/lib/rclone/rclone.conf
      mkdir -p /var/lib/rclone && chmod 700 /var/lib/rclone

      user=$(cat ${config.sops.secrets.proton-username.path})
      [ -n "$user" ] || { echo "proton-username is empty; fill it with scripts/secrets-sync.sh"; exit 0; }

      # created once, rclone caches session tokens in it
      if [ ! -s "$conf" ]; then
        rclone --config "$conf" config create proton protondrive \
          username="$user" \
          password="$(rclone obscure "$(cat ${config.sops.secrets.proton-password.path})")" \
          otp_secret_key="$(cat ${config.sops.secrets.proton-totp-secret.path})" \
          --non-interactive >/dev/null
      fi

      # everything but bulk, as plain browsable folders beside the kopia repo in BACKUPS;
      # sync mirrors, --backup-dir keeps 30 days of changes and deletions
      stamp=$(date +%Y-%m-%d)
      remote=proton:homelab-offsite
      for tree in BACKUPS data documents syncthing; do
        echo ">>> $tree -> $remote/$tree"
        rclone --config "$conf" sync "${source}/$tree" "$remote/$tree" \
          --backup-dir "$remote/.trash/$stamp/$tree" \
          --exclude "/qbittorrent-incomplete/**" \
          --transfers 4 --checkers 8 --retries 3 --low-level-retries 10 \
          --stats 5m --stats-one-line
      done
      rclone --config "$conf" delete "$remote/.trash" --min-age 30d --rmdirs || true

      d=/var/lib/node-exporter-textfile; mkdir -p $d
      {
        echo "# HELP homelab_offsite_last_success_timestamp_seconds Unix time of the last Proton Drive sync."
        echo "# TYPE homelab_offsite_last_success_timestamp_seconds gauge"
        echo "homelab_offsite_last_success_timestamp_seconds $(date +%s)"
      } > $d/proton_sync.prom.tmp
      mv $d/proton_sync.prom.tmp $d/proton_sync.prom
    '';
  };

  # after the 02:00 snapshot
  systemd.timers.proton-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "04:00"; Persistent = true; RandomizedDelaySec = "30m"; };
  };
}
