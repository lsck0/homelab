# kopia: snapshots the nas it runs on, and proton-sync mirrors the repository off-site to proton drive
#
# Off-site goes through proton's own drive cli, vendored as its prebuilt linux-x64 binary (a bun-compiled elf):
# rclone's proton backend is dead, proton moved its api past rclone's unmaintained go-proton-api and rejects every
# rclone version with 422 "no longer supported".
#
# Only the repository goes up: it is encrypted, deduplicated and holds every snapshot; uploading the raw trees beside
# it doubled the remote, and merge uploads never dropped what they deleted. The cli (0.8.0) has no mirror mode (its
# folder strategies are merge, rename, replace and skip, and replace re-uploads the whole repo), so proton-sync diffs
# the repo's file list against the previous run's manifest, trashes what vanished by path, then deletes it from the
# trash (proton never empties it, and trash counts against the quota). The manifest is the only memory of what is
# remote: lose it and the remote keeps what was deleted before (bounded by the repo's size); to start over, trash
# /my-files/homelab-offsite/BACKUPS/kopia and the manifest. An upload's verdict comes from the cli's json summary
# (-j, the last stdout line), never from the log text, where a warning shaped like an item error would flip it:
# sockets and symlinks are expected skips, a file changed mid-upload (kopia.maintenance rewritten) gets one more try.
#
# Retention: prometheus and loki compact, rewriting their blocks, so every snapshot pins fresh copies for up to two
# years. Loki keeps 14 days of logs, so its tree is not backed up; prometheus keeps 10 years, so it is a source of
# its own with a short retention. Registry images are rebuilt from git by ci.
{ config, lib, pkgs, catalog, site, ... }:
let
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
    # the keychain store dlopens libsecret and glib; unused (unsafe_file), but the binary must always find them
    postFixup = ''
      wrapProgram $out/bin/proton-drive \
        --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.libsecret pkgs.glib ]}
    '';
  };
  # one-time sign-in on the nas: prints an account.proton.me url; proton-sync reuses and refreshes the session
  protonLogin = pkgs.writeShellScriptBin "proton-drive-login" ''
    export HOME=${protonDir} PROTON_DRIVE_CREDENTIALS_STORE=unsafe_file PROTON_DRIVE_CACHE_DIR=${protonDir}
    ${pkgs.coreutils}/bin/mkdir -p ${protonDir}
    exec ${protonDriveCli}/bin/proton-drive auth login "$@"
  '';
  source = "/srv/nas";
  # vm-105's tsdb, exported from the nas; ignored in source, snapshotted as a source of its own
  prometheusDir = "${source}/data/prometheus";
  repo = "${source}/BACKUPS/kopia";
  stateDir = "/var/lib/kopia";
  logDir = "/var/log/kopia";
  cacheDir = "/var/cache/kopia";
  configFile = "${stateDir}/repository.config";
  snapshotTime = "02:00";
  # --without-password: authelia gates the route
  serverPort = catalog.internal.kopia.port;

  kopiaEnv = ''
    export KOPIA_CONFIG_PATH=${configFile}
    export KOPIA_PASSWORD="$(cat ${config.sops.secrets.kopia-password.path})"
    export KOPIA_CHECK_FOR_UPDATES=false
    export KOPIA_LOG_DIR=${logDir}
    export KOPIA_CACHE_DIRECTORY=${cacheDir}
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
    cmd="''${1:-help}"; [ $# -eq 0 ] || shift
    export TZ=${site.timeZone} TZDIR=''${TZDIR:-/etc/zoneinfo}
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
               echo ">>> Stop the service that uses it first (see its src/instances/*/instance.nix)."
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

  environment.systemPackages = [ kopiaWrapper restoreScript protonDriveCli protonLogin ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "d ${logDir} 0700 root root -"
    "d ${cacheDir} 0700 root root -"
    # the proton session, written by the one-time login and refreshed by proton-sync
    "d ${protonDir} 0700 root root -"
  ];

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
      # --add-ignore merges into a set, so every boot's rerun adds nothing twice; the ignores are in the header
      kopia policy set ${source} \
        --snapshot-time=${snapshotTime} \
        --compression=zstd \
        --keep-latest=3 --keep-hourly=0 --keep-daily=7 --keep-weekly=8 --keep-monthly=12 --keep-annual=2 \
        --add-ignore=/BACKUPS --add-ignore=lost+found --add-ignore='*.tmp' \
        --add-ignore=/bulk \
        --add-ignore=/documents/archive \
        --add-ignore=/data/prometheus --add-ignore=/data/loki --add-ignore=/data/registry \
        --one-file-system=false
      # the nas's own local state: syncthing identity and filebrowser users live off /srv/nas
      for extra in /var/lib/syncthing /var/lib/filebrowser; do
        kopia policy set "$extra" --snapshot-time=${snapshotTime} --compression=zstd \
          --keep-latest=3 --keep-daily=7 --keep-weekly=8 --keep-monthly=12
        # the server only schedules sources that already have a snapshot
        kopia snapshot list "$extra" --json | jq -e 'length > 0' >/dev/null || kopia snapshot create "$extra"
      done
      # a lost disk costs at most a day of metrics; older snapshots would only pin compacted-away blocks
      if [ -d ${prometheusDir} ]; then
        kopia policy set ${prometheusDir} --snapshot-time=${snapshotTime} --compression=zstd \
          --keep-latest=2 --keep-hourly=0 --keep-daily=3 --keep-weekly=2 --keep-monthly=0 --keep-annual=0
        # the list of a nested path also holds the /srv/nas snapshots that contain it, so match the source itself
        kopia snapshot list ${prometheusDir} --json | jq -e --arg p ${prometheusDir} 'any(.[]; .source.path == $p)' \
          >/dev/null || kopia snapshot create ${prometheusDir}
      fi
    '';
  };

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
        --address=http://0.0.0.0:${toString serverPort}
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
      d=${config.homelab.textfileDir}; mkdir -p $d
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

  networking.firewall.allowedTCPPorts = [ serverPort ];
  homelab.ingressOnly.ports = [ serverPort ];

  # the repository shares the data's disk; the header says how the mirror works
  systemd.services.proton-sync = {
    description = "Mirror the Kopia repository to Proton Drive";
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
    path = [ protonDriveCli pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.jq ];
    script = ''
      # nixos starts scripts with set -e; a failed batch must not skip the rest, and create-folder-exists is non-fatal
      set +e -uo pipefail
      shopt -s nullglob

      # paths per trash or delete call: the cli lists each path's folder, so a bound keeps a call's runtime and argv small
      PRUNE_BATCH_COUNT=100
      # maintenance drops a few percent a night; more vanishing is a local loss the off-site copy exists to survive
      PRUNE_SHARE_MAX_PERCENT=50
      # touch to let the next run prune past PRUNE_SHARE_MAX_PERCENT once, after checking the loss is intended
      prune_allow_large=${protonDir}/prune-allow-large
      # repo files (relative paths) earlier runs uploaded, or failed to trash
      manifest=${protonDir}/offsite-manifest.txt
      # remote names trashed but not yet deleted from the trash
      purge_queue=${protonDir}/offsite-purge.txt

      if [ ! -s ${protonDir}/auth-session.json ]; then
        echo "no proton session; run 'proton-drive-login' on this host once (opens a sign-in url)"
        exit 0
      fi
      # an unmounted or wiped repo must not read as a repo whose every blob was deleted
      if [ ! -f ${repo}/kopia.repository.f ]; then
        echo "no kopia repository at ${repo}; refusing to sync"
        exit 1
      fi

      # posix paths; the top-level section is /my-files (see `filesystem list /`)
      root=/my-files/homelab-offsite
      # same remote layout as when all of BACKUPS went up, so the repo uploaded before is reused
      remote=$root/BACKUPS/${baseNameOf repo}
      # remote parents must exist before an upload; create-folder errors if present, so ignore it
      proton-drive filesystem create-folder /my-files homelab-offsite >/dev/null 2>&1 || true
      proton-drive filesystem create-folder "$root" BACKUPS >/dev/null 2>&1 || true

      # 0 uploaded, 2 only files changed mid-upload (retry once), 1 anything else; unchanged files are skipped by hash
      upload() {
        local out err rc real summary
        out=$(mktemp); err=$(mktemp)
        proton-drive filesystem upload -j -f create-new-revision -d merge -t "$1" "$2" > "$out" 2> "$err"
        rc=$?
        cat "$err" >&2
        summary=$(tail -n 1 "$out")
        rm -f "$out" "$err"
        [ "$rc" = 0 ] && return 0
        # no summary is the call itself failing: session expired, network down
        jq -e '.failures | type == "array"' <<<"$summary" >/dev/null 2>&1 || return 1
        echo ">>> upload failures: $(jq -c '.failures' <<<"$summary")" >&2
        real=$(jq -c '[.failures[].error | select(contains("Not a regular file or directory") | not)]' <<<"$summary")
        [ "$real" = "[]" ] && return 0
        jq -e 'all(.[]; startswith("IntegrityError"))' <<<"$real" >/dev/null && return 2
        return 1
      }

      # runs `filesystem <verb>` on the paths, prints those still there; gone_pattern in the error means already gone
      remote_apply() {
        local verb=$1 gone_pattern=$2 out err item
        shift 2
        err=$(mktemp)
        out=$(proton-drive filesystem "$verb" -j "$@" 2>"$err")
        if [ $? = 0 ] && jq -e 'all(.[]; .ok == true)' <<<"$out" >/dev/null 2>&1; then
          rm -f "$err"
          return 0
        fi
        # one unresolvable path fails the whole call before anything moves: retry one by one
        for item in "$@"; do
          out=$(proton-drive filesystem "$verb" -j "$item" 2>"$err")
          if [ $? = 0 ] && jq -e 'all(.[]; .ok == true)' <<<"$out" >/dev/null 2>&1; then continue; fi
          grep -q "$gone_pattern" "$err" && continue
          echo ">>> $verb $item failed: $(head -c 300 "$err") $(head -c 300 <<<"$out")" >&2
          echo "$item"
        done
        rm -f "$err"
      }

      # remote_apply over stdin's lines in batches of PRUNE_BATCH_COUNT
      remote_apply_batched() {
        local verb=$1 gone_pattern=$2 items i
        mapfile -t items
        for ((i = 0; i < ''${#items[@]}; i += PRUNE_BATCH_COUNT)); do
          remote_apply "$verb" "$gone_pattern" "''${items[@]:i:PRUNE_BATCH_COUNT}"
        done
      }

      ok=1
      touch "$manifest" "$purge_queue"
      current=$(mktemp)
      gone=$(mktemp)
      kept=$(mktemp)
      # listed before the upload: a blob written during it is in the next run's list and upload
      find ${repo} -type f -printf '%P\n' | LC_ALL=C sort > "$current"

      echo ">>> ${repo} -> $remote"
      upload ${repo} "$root/BACKUPS"
      case $? in
        0) ;;
        2) echo ">>> ${repo} changed during the upload, once more"; upload ${repo} "$root/BACKUPS" || ok=0 ;;
        *) ok=0 ;;
      esac

      LC_ALL=C sort -u "$manifest" | LC_ALL=C comm -23 - "$current" > "$gone"
      gone_count=$(wc -l < "$gone")
      known_count=$(wc -l < "$manifest")
      if [ "$ok" != 1 ]; then
        # a failed upload says nothing good about the session or the source; prune next time
        cp "$gone" "$kept"
      elif [ "$gone_count" -gt 0 ] && [ $((gone_count * 100)) -gt $((known_count * PRUNE_SHARE_MAX_PERCENT)) ] \
          && [ ! -e "$prune_allow_large" ]; then
        echo ">>> $gone_count of $known_count uploaded repo files are gone locally, over $PRUNE_SHARE_MAX_PERCENT%;"
        echo ">>> not pruning the off-site copy. if intended: touch $prune_allow_large and rerun"
        cp "$gone" "$kept"
        ok=0
      else
        rm -f "$prune_allow_large"
        echo ">>> trashing $gone_count remote files the repo dropped"
        sed "s|^|$remote/|" "$gone" | remote_apply_batched trash 'Node not found' | sed "s|^$remote/||" > "$kept"
        # blob names are content hashes, unique in the trash, so deleting by name cannot hit another item
        LC_ALL=C comm -23 "$gone" <(LC_ALL=C sort "$kept") | sed 's|.*/||' >> "$purge_queue"
        [ -s "$kept" ] && ok=0
      fi
      # the next run retries what could not be trashed
      LC_ALL=C sort -u "$current" "$kept" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"

      # raw trees earlier versions uploaded beside the repo go, renamed first so a trash delete by name hits only them
      proton-drive filesystem list -j "$root" 2>/dev/null \
        | jq -r '.[] | .name.value // empty | select(. != "BACKUPS")' 2>/dev/null \
        | while IFS= read -r name; do
            unique="homelab-offsite-stray-$name-$(date +%s)"
            echo ">>> trashing $root/$name, uploaded by an earlier version"
            proton-drive filesystem rename "$root/$name" "$unique" </dev/null >/dev/null || exit 1
            [ -z "$(echo "$root/$unique" | remote_apply_batched trash 'Node not found')" ] || exit 1
            echo "$unique" >> "$purge_queue"
          done
      [ "''${PIPESTATUS[2]}" = 0 ] || ok=0

      if [ -s "$purge_queue" ]; then
        echo ">>> deleting $(wc -l < "$purge_queue") trashed files for good"
        sed 's|^|/trash/|' "$purge_queue" | remote_apply_batched delete 'Trashed node not found' \
          | sed 's|^/trash/||' > "$purge_queue.tmp"
        mv "$purge_queue.tmp" "$purge_queue"
        [ -s "$purge_queue" ] && ok=0
      fi
      rm -f "$current" "$gone" "$kept"

      [ "$ok" = 1 ] || { echo "one or more uploads or prunes failed"; exit 1; }

      # freshness metric only on a fully successful run
      d=${config.homelab.textfileDir}; mkdir -p $d
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
