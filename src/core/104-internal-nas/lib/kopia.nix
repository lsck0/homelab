# kopia: snapshots the nas it runs on, and proton-sync mirrors the repository off-site to proton drive;
# proton-sync-share mirrors the syncthing folder there as plain files beside it
#
# Off-site goes through proton's own drive cli, vendored as its prebuilt linux-x64 binary (a bun-compiled elf):
# rclone's proton backend is dead, proton moved its api past rclone's unmaintained go-proton-api and rejects every
# rclone version with 422 "no longer supported".
#
# The repository goes up whole: it is encrypted, deduplicated and holds every snapshot. Of the raw trees only the
# syncthing folder does, browsable in proton drive (which encrypts end to end itself); its history is the repository's.
# The cli (0.8.0) has no mirror mode (its folder strategies are merge, rename, replace and skip, and replace re-uploads
# everything), so both mirrors run proton-mirror.sh, which diffs the upload against the previous run's manifest and
# prunes what vanished, trash and all (proton never empties it, and trash counts against the quota); its header says
# how. To start a mirror over, trash its remote folder and delete its manifest.
#
# Retention: prometheus and loki compact, rewriting their blocks, so every snapshot pins fresh copies for up to two
# years. Loki keeps 14 days of logs, so its tree is not backed up; prometheus keeps 10 years, so it is a source of
# its own with a short retention. Registry images are rebuilt from git by ci.
#
# Verification: kopia-verify re-reads a share of the stored files every week and downloads a few repository blobs
# back from proton drive, comparing them with the local ones; each part publishes its own freshness metric.
#
# A proton outage (modules/upstream) skips the night's upload or sample: the off-site copy stays as it was.
{ config, lib, pkgs, catalog, site, inventory, nasClients, upstream, ... }:
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
  # vm-103's tsdb, exported from the nas; ignored in source, snapshotted as a source of its own
  prometheusDir = "${source}/data/prometheus";
  repo = "${source}/BACKUPS/kopia";
  stateDir = "/var/lib/kopia";
  logDir = "/var/log/kopia";
  cacheDir = "/var/cache/kopia";
  configFile = "${stateDir}/repository.config";
  snapshotTime = "02:00";
  serverPort = catalog.internal.kopia.port;
  # share of the stored files a verify reads back: every file about every 20 weeks
  verifyFilesPercent = 5;
  # after the 02:00 snapshot and the 04:00 off-site upload's usual end
  verifyAt = "Sun 06:00";
  # repository blobs downloaded back from proton drive per verify, a few hundred MiB at most
  offsiteSampleCount = 4;
  # one proton session: proton-sync and the off-site sample never run the cli at once
  protonLock = "/run/proton-drive.lock";
  protonEnv = {
    HOME = protonDir;
    PROTON_DRIVE_CREDENTIALS_STORE = "unsafe_file";
    PROTON_DRIVE_CACHE_DIR = protonDir;
  };
  # the remote layout the mirrors upload to, posix paths below the drive's /my-files section
  offsiteRoot = "/my-files/homelab-offsite";
  # same layout as when all of BACKUPS went up, so the repo uploaded before is reused
  offsiteRepoParent = "${offsiteRoot}/BACKUPS";
  offsiteRepo = "${offsiteRepoParent}/${baseNameOf repo}";
  manifest = "${protonDir}/offsite-manifest.txt";
  # the syncthing folder main.nix declares, mirrored as plain files to offsiteRoot/<its name>; none in a test
  shareDir = config.services.syncthing.settings.folders.sync.path or null;
  # syncthing's own: the folder marker, file versions, and temp files of a pull in progress (unix and windows names)
  shareExcludes = [ ".stfolder" ".stversions" ".syncthing.*.tmp" "~syncthing~*.tmp" ];
  # after the repository's 04:00 upload, usually done within the hour
  repoSyncAt = "04:00";
  shareSyncAt = "05:00";
  syncDelay = "30m";
  # the share's first upload (122 GiB, 2026-10) spans nights: each run resumes, content-skipping what arrived, and ends
  # before the next night's repository upload waits on the lock
  shareSyncTimeout = "20h";
  # a run may prune this much of what a mirror uploaded; repository maintenance drops a few percent a night, a share
  # loses a folder now and then; more is a local loss the off-site copy exists to survive
  repoGoneMaxPercent = 50;
  shareGoneMaxPercent = 20;
  probeProton = pkgs.writeShellScript "proton-probe" "exec ${upstream.run} proton";
  protonMirror = import ./proton-mirror.nix { inherit pkgs; };
  # one mirror's unit: proton-mirror.sh under the lock, its success time as homelab_offsite_last_success_timestamp_seconds
  # labelled mirror=<label>, written to <textfile>.prom
  mirrorUnit = { description, mode, source, target, marker, manifest, maxGonePercent, excludes ? [ ], label, textfile, timeout }: {
    inherit description;
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    # never restart on a nixos switch: this multi-hour upload would block the whole deploy; the timer picks up changes
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = timeout;
      # 1.8G peak on 2026-10-01; above that it is a leak, and nfs and smb keep the rest of the 3G guest
      MemoryMax = "2G";
      SuccessExitStatus = [ upstream.unavailable ];
      CPUWeight = "idle";
      IOSchedulingClass = "idle";
      ExecStart = lib.getExe protonMirror;
    };
    path = [ protonDriveCli ];
    environment = protonEnv // {
      PROTON_MIRROR_MODE = mode;
      PROTON_MIRROR_SOURCE = source;
      PROTON_MIRROR_TARGET = target;
      PROTON_MIRROR_ROOT = offsiteRoot;
      PROTON_MIRROR_ROOT_KEEP = toString ([ (baseNameOf offsiteRepoParent) ] ++ lib.optional (shareDir != null) (baseNameOf shareDir));
      PROTON_MIRROR_MARKER = marker;
      PROTON_MIRROR_MANIFEST = manifest;
      PROTON_MIRROR_MAX_GONE_PERCENT = toString maxGonePercent;
      PROTON_MIRROR_EXCLUDES = toString excludes;
      PROTON_MIRROR_STATE = protonDir;
      PROTON_MIRROR_LOCK = protonLock;
      PROTON_MIRROR_PROBE = probeProton;
      PROTON_MIRROR_METRIC = pkgs.writeShellScript "${textfile}-metric" ''exec ${metricWrite} ${lib.escapeShellArgs [
        textfile "homelab_offsite_last_success_timestamp_seconds" "Unix time of the last Proton Drive mirror run."
      ]} "$1" ${lib.escapeShellArg "{mirror=\"${label}\"}"}'';
    };
  };
  mirrorTimer = at: {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = at; Persistent = true; RandomizedDelaySec = syncDelay; };
  };
  # every guest's local state copy (modules/local-state), "<share name> <guest> <address>" per line
  guestOf = ip: "vm-${lib.findFirst (id: inventory.${id}.ip == ip) null (lib.attrNames inventory)}";
  localStates = pkgs.writeText "local-states" (lib.concatStrings (lib.concatLists (lib.mapAttrsToList (ip: shares:
    map (s: "${lib.removePrefix "${source}/data/" s.path} ${guestOf ip} ${ip}\n") (lib.filter (s: s.localState) shares)
  ) nasClients)));
  # metric-write <file> <name> <help> <value> [labels]: one gauge, renamed into place
  metricWrite = pkgs.writeShellScript "metric-write" ''
    d=${config.homelab.textfileDir}
    ${pkgs.coreutils}/bin/mkdir -p "$d"
    printf '# HELP %s %s\n# TYPE %s gauge\n%s%s %s\n' "$2" "$3" "$2" "$2" "''${5:-}" "$4" > "$d/$1.prom.tmp"
    ${pkgs.coreutils}/bin/mv "$d/$1.prom.tmp" "$d/$1.prom"
  '';

  kopiaEnv = ''
    export KOPIA_CONFIG_PATH=${configFile}
    export KOPIA_PASSWORD="$(cat ${config.sops.secrets.kopia-password.path})"
    export KOPIA_CHECK_FOR_UPDATES=false
    export KOPIA_LOG_DIR=${logDir}
    export KOPIA_CACHE_DIRECTORY=${cacheDir}
    export PATH="${lib.makeBinPath [ pkgs.kopia pkgs.jq pkgs.coreutils pkgs.curl pkgs.systemd pkgs.gawk ]}:$PATH"
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
               echo ">>> Stop the service that uses it first (see its instance.nix)."
               if [ "$yes" != "--yes" ]; then
                 printf ">>> type 'yes' to proceed: "; read -r ok; [ "$ok" = yes ] || { echo aborted; exit 1; }
               fi
               kopia restore "$obj/data/$name" "${source}/data/$name" \
                 --overwrite-files --overwrite-directories --overwrite-symlinks --no-ignore-permission-errors
               # a guest's local state copy: a new generation marked restored makes its seed replace the local copy
               entry=$(awk -v n="$name" '$1 == n { print $2, $3 }' ${localStates})
               if [ -n "$entry" ]; then
                 read -r guest ip <<<"$entry"
                 # modules/local-state's restored mark, written in place
                 printf 'restored-%s\n' "$(cat /proc/sys/kernel/random/uuid)" > "${source}/data/$name/.generation"
                 echo ">>> $name is $guest's local state: it takes the restore when the app starts, at its nightly"
                 echo ">>> mirror, or now: ssh root@$ip systemctl start $name-reseed"
               fi
               echo ">>> done: ${source}/data/$name restored from $when" ;;
      restore) # restore <snapshot> <subpath> <target-dir>
               sel="''${1:?snapshot}"; sub="''${2:?subpath under ${source}}"; tgt="''${3:?target dir}"
               obj=$(pick "$sel" | jq -r '.rootEntry.obj // empty')
               [ -n "$obj" ] || { echo "no snapshot matches $sel"; exit 1; }
               mkdir -p "$tgt"
               kopia restore "$obj/$sub" "$tgt" ;;
      now)     kopia snapshot create ${source} ;;
      verify)  kopia snapshot verify --verify-files-percent=${toString verifyFilesPercent} ;;
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
  nas-restore verify                       re-read ${toString verifyFilesPercent}% of the stored files

Raw kopia with the repository connected: kopia-nas <args>
Repo: ${repo}
EOF
      ;;
    esac
  '';
in {
  homelab.textfiles = [ "nas_backup" "proton_sync" "proton_sync_share" "backup_verify_repository" "backup_verify_offsite" ];

  sops.secrets.kopia-password = {};
  # the web ui's basic auth (user kopia) behind authelia: the port stays closed to whoever else reaches it
  sops.secrets.kopia-server-password = {};

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
      KOPIA_SERVER_PASSWORD="$(cat ${config.sops.secrets.kopia-server-password.path})"
      export KOPIA_SERVER_PASSWORD
      exec kopia server start --ui --insecure --address=http://0.0.0.0:${toString serverPort}
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

  # the repository shares the data's disk; the header says how the mirrors work
  systemd.services.proton-sync = mirrorUnit {
    description = "Mirror the Kopia repository to Proton Drive";
    mode = "blobs";
    source = repo;
    target = offsiteRepoParent;
    marker = "kopia.repository.f";
    inherit manifest;
    maxGonePercent = repoGoneMaxPercent;
    label = "kopia";
    textfile = "proton_sync";
    # first run uploads everything; unchanged files are content-skipped on later runs
    timeout = "12h";
  };
  # after the 02:00 snapshot
  systemd.timers.proton-sync = mirrorTimer repoSyncAt;

  systemd.services.proton-sync-share = lib.mkIf (shareDir != null) (mirrorUnit {
    description = "Mirror the Syncthing folder to Proton Drive as plain files";
    mode = "tree";
    source = shareDir;
    target = offsiteRoot;
    marker = ".stfolder";
    manifest = "${protonDir}/share-manifest.txt";
    maxGonePercent = shareGoneMaxPercent;
    excludes = shareExcludes;
    label = "share";
    textfile = "proton_sync_share";
    timeout = shareSyncTimeout;
  });
  systemd.timers.proton-sync-share = lib.mkIf (shareDir != null) (mirrorTimer shareSyncAt);

  # the header says what a verify reads back; a failed part leaves its metric stale, which grafana alerts on
  systemd.services.kopia-verify = {
    description = "Re-read a share of the Kopia repository and sample its off-site copy";
    after = [ "kopia-init.service" "network-online.target" ];
    requires = [ "kopia-init.service" ];
    wants = [ "network-online.target" ];
    restartIfChanged = false;
    environment = protonEnv;
    path = [ protonDriveCli pkgs.util-linux pkgs.diffutils pkgs.gnugrep ];
    serviceConfig = {
      Type = "oneshot";
      CPUWeight = "idle";
      IOSchedulingClass = "idle";
      MemoryMax = "1G";
      SuccessExitStatus = [ upstream.unavailable ];
    };
    script = ''
      ${kopiaEnv}
      kopia snapshot verify --verify-files-percent=${toString verifyFilesPercent}
      ${metricWrite} backup_verify_repository homelab_backup_verify_last_success_timestamp_seconds \
        "Unix time of the last Kopia repository verify." "$(date +%s)"

      [ -s ${protonDir}/auth-session.json ] || { echo "no proton session: off-site copy not sampled"; exit 0; }
      ${upstream.run} proton || exit $?
      exec 9>${protonLock}
      flock 9
      sample=$(mktemp -d)
      trap 'rm -rf "$sample"' EXIT
      # pack blobs only (p and q, flat or sharded as p00/2ab/<rest>): written once, so the remote copy of an uploaded one
      # equals the local one
      grep -E '^[pq][0-9a-f]' ${manifest} | while IFS= read -r rel; do [ -f "${repo}/$rel" ] && echo "$rel"; done \
        | shuf -n ${toString offsiteSampleCount} > "$sample/list"
      [ -s "$sample/list" ] || { echo "no uploaded pack blob to sample yet"; exit 0; }
      while IFS= read -r rel; do
        if ! proton-drive filesystem download -f remove "${offsiteRepo}/$rel" "$sample" </dev/null >/dev/null; then
          ${upstream.run} proton || exit $?
          echo "off-site $rel does not download" >&2
          exit 1
        fi
        cmp "$sample/$(basename "$rel")" "${repo}/$rel" || { echo "off-site $rel differs from the local blob" >&2; exit 1; }
        echo "off-site $rel matches"
      done < "$sample/list"
      ${metricWrite} backup_verify_offsite homelab_offsite_verify_last_success_timestamp_seconds \
        "Unix time of the last off-site sample that matched the local repository." "$(date +%s)"
    '';
  };
  systemd.timers.kopia-verify = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = verifyAt; Persistent = true; RandomizedDelaySec = "1h"; };
  };
}
