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
    ${pkgs.coreutils}/bin/mkdir -p ${protonDir}
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
  sops.secrets.kopia-password = {};

  # protonDriveCli + protonLogin front the off-site backup (see proton-sync below)
  environment.systemPackages = [ kopiaWrapper restoreScript protonDriveCli protonLogin ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kopia 0700 root root -"
    "d /var/log/kopia 0700 root root -"
    "d /var/cache/kopia 0700 root root -"
    # proton session store, written by the one-time login and refreshed by proton-sync
    "d ${protonDir} 0700 root root -"
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
        --add-ignore=/bulk \
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
    # snapshots yield to nfs and smb, the guest's actual job
    serviceConfig = { Restart = "always"; RestartSec = 10; CPUWeight = "idle"; IOSchedulingClass = "idle"; MemoryMax = "1G"; };
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

  # off-site proton drive mirror (local repo shares the data's disk); cli, login and session dir defined with kopia's above
  systemd.services.proton-sync = {
    description = "Mirror the NAS, all but bulk, to Proton Drive";
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    # never restart on a nixos switch: this multi-hour upload would block the whole deploy; the timer picks up changes
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      # first run uploads everything; unchanged files are content-skipped on later runs
      TimeoutStartSec = "12h";
      # 1.8G peak on 2026-10-01; above that it is a leak, and nfs and smb keep the rest of the 3G guest
      MemoryMax = "2G";
      CPUWeight = "idle";
      IOSchedulingClass = "idle";
    };
    environment = {
      HOME = protonDir;
      PROTON_DRIVE_CREDENTIALS_STORE = "unsafe_file";
      PROTON_DRIVE_CACHE_DIR = protonDir;
    };
    path = [ protonDriveCli pkgs.coreutils ];
    script = ''
      # nixos starts scripts with set -e; one tree failing must not skip the rest, and create-folder-exists is non-fatal
      set +e -uo pipefail
      # dotglob: the per-child loop below would skip .git, .config and the like
      shopt -s nullglob dotglob

      if [ ! -s ${protonDir}/auth-session.json ]; then
        echo "no proton session; run 'proton-drive-login' on this host once (opens a sign-in url)"
        exit 0
      fi

      # posix paths; the top-level section is /my-files (see `filesystem list /`)
      root=/my-files/homelab-offsite
      # remote parents must exist before an upload; create-folder errors if present, so ignore it
      proton-drive filesystem create-folder /my-files homelab-offsite >/dev/null 2>&1 || true

      # upload skips unchanged files by content hash; changed files keep a new revision, folders merge.
      # each tree is uploaded child by child, not whole: the cli has no exclude flag, and it refuses to
      # recurse across a mount point, so a bind mount like documents/archive must be its own upload root.
      # one process per child: the cli holds per-file state for its whole call, and all of data in one
      # call grew to 1.9G and was oom-killed on this 3G guest (2026-09-29).
      # skipped in data: the prometheus/loki tsdbs, which rewrite thousands of
      # chunk files a day (a new remote revision each) and are only regenerable monitoring history.
      # the cli fails the whole call for items it cannot upload: symlinks (crowdsec hub links, grafana/conf
      # into the nix store) and sockets are expected skips; a file changed mid-upload (a live sqlite db)
      # gets one more try; anything else fails the run
      upload() {
        local out
        out=$(mktemp)
        proton-drive filesystem upload -f create-new-revision -d merge -t "$1" "$2" 2>&1 | tee "$out"
        local rc=''${PIPESTATUS[0]} items real
        items=$(grep -E '^\s+- .*: [A-Za-z]+Error:' "$out" || true)
        rm -f "$out"
        [ "$rc" = 0 ] && return 0
        # a failure naming no item is the call itself: session expired, network down
        [ -n "$items" ] || return 1
        real=$(grep -v 'Not a regular file or directory' <<<"$items" || true)
        [ -n "$real" ] || return 0
        grep -qv 'IntegrityError' <<<"$real" && return 1
        return 2
      }

      ok=1
      for tree in BACKUPS documents syncthing data; do
        proton-drive filesystem create-folder "$root" "$tree" >/dev/null 2>&1 || true
        for p in ${source}/$tree/*; do
          if [ "$tree" = data ]; then
            case "$(basename "$p")" in prometheus|loki) continue ;; esac
          fi
          echo ">>> $p -> $root/$tree"
          upload "$p" "$root/$tree"
          case $? in
            0) ;;
            2) echo ">>> $p changed during the upload, once more"; upload "$p" "$root/$tree" || ok=0 ;;
            *) ok=0 ;;
          esac
        done
      done

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
