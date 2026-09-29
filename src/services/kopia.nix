# kopia: snapshots the nas it runs on, mirrors backups off-site to proton drive
{ config, lib, pkgs, ... }:
let
  # off-site is proton drive via proton's own drive cli. rclone's proton backend is dead:
  # proton moved its api past rclone's unmaintained go-proton-api and rejects every rclone
  # version/app_version with 422 "no longer supported". the official cli is the only client
  # proton keeps working, so we vendor its prebuilt linux-x64 binary (bun-compiled elf).
  protonDir = "/var/lib/proton-drive";
  protonDriveCli = pkgs.stdenv.mkDerivation rec {
    pname = "proton-drive-cli";
    version = "0.8.0";
    src = pkgs.fetchurl {
      url = "https://proton.me/download/drive/cli/${version}/linux-x64/proton-drive";
      hash = "sha256-lEPXcXGciSeQ2xfm8C7Nma18U1kzKfOmfHdnfc5XdzU=";
    };
    dontUnpack = true;
    dontStrip = true; # stripping corrupts the bun-compiled binary
    nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
    buildInputs = [ (pkgs.lib.getLib pkgs.stdenv.cc.cc) ];
    installPhase = "install -Dm755 $src $out/bin/proton-drive";
    # libsecret/glib are dlopened by the keychain store; we use unsafe_file, but wrap them
    # in so the binary never fails to find them and the keychain store stays available.
    postFixup = ''
      wrapProgram $out/bin/proton-drive \
        --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libsecret pkgs.glib ]}
    '';
  };
  # one-time interactive sign-in: prints an account.proton.me url, poll-forks the session
  # into protonDir. run it once on the nas; proton-sync reuses and auto-refreshes the session.
  protonLogin = pkgs.writeShellScriptBin "proton-drive-login" ''
    export HOME=${protonDir} PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file PROTON_DRIVE_CACHE_DIR=${protonDir}
    mkdir -p ${protonDir}
    exec ${protonDriveCli}/bin/proton-drive auth login "$@"
  '';
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
      # the nas's own local state: syncthing identity and filebrowser users live off /srv/nas
      for extra in /var/lib/syncthing /var/lib/filebrowser; do
        kopia policy set "$extra" --snapshot-time=02:00 --compression=zstd \
          --keep-latest=3 --keep-daily=7 --keep-weekly=8 --keep-monthly=12
        # the server only schedules sources that already have a snapshot
        kopia snapshot list "$extra" --json | jq -e 'length > 0' >/dev/null || kopia snapshot create "$extra"
      done
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

  # -----------------------------------------------------------------------------
  # OFF-SITE: PROTON DRIVE (repo shares the data's disk)
  environment.systemPackages = [ protonDriveCli protonLogin ];
  # session store lives here, written by the one-time login and refreshed by proton-sync
  systemd.tmpfiles.rules = [ "d ${protonDir} 0700 root root -" ];

  systemd.services.proton-sync = {
    description = "Mirror the NAS, all but bulk, to Proton Drive";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      # first run uploads everything; unchanged files are content-skipped on later runs
      TimeoutStartSec = "12h";
    };
    environment = {
      HOME = protonDir;
      PROTON_DRIVE_CREDENTIALS_STORE = "unsafe_file";
      PROTON_DRIVE_CACHE_DIR = protonDir;
    };
    path = [ protonDriveCli pkgs.coreutils ];
    script = ''
      # not -e: one tree failing must not skip the rest, and create-folder-exists is non-fatal
      set -uo pipefail
      shopt -s nullglob

      if [ ! -s ${protonDir}/auth-session.json ]; then
        echo "no proton session; run 'proton-drive-login' on this host once (opens a sign-in url)"
        exit 0
      fi

      root=MyFiles/homelab-offsite
      # remote parents must exist before an upload; create-folder errors if present, so ignore it
      proton-drive filesystem create-folder MyFiles homelab-offsite >/dev/null 2>&1 || true
      proton-drive filesystem create-folder "$root" data >/dev/null 2>&1 || true

      # upload skips unchanged files by content hash; changed files keep a new revision, folders merge.
      # the cli has no exclude flag, so bulk (never here) and data's churny incomplete-torrents dir
      # are handled by uploading data's children one by one instead of the whole tree.
      ok=1
      for tree in BACKUPS documents syncthing; do
        echo ">>> $tree -> $root/$tree"
        proton-drive filesystem upload -f create-new-revision -d merge -t "${source}/$tree" "$root" || ok=0
      done

      kids=()
      for p in ${source}/data/*; do
        [ "$(basename "$p")" = qbittorrent-incomplete ] && continue
        kids+=("$p")
      done
      if [ "''${#kids[@]}" -gt 0 ]; then
        echo ">>> data (''${#kids[@]} items) -> $root/data"
        proton-drive filesystem upload -f create-new-revision -d merge -t "''${kids[@]}" "$root/data" || ok=0
      fi

      [ "$ok" = 1 ] || { echo "one or more uploads failed"; exit 1; }

      # freshness metric only on a fully successful run
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
