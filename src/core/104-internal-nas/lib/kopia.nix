# kopia: snapshots the nas it runs on, and proton-sync mirrors the repository off-site to proton drive;
# proton-bisync keeps the syncthing folder in sync with a plain-file copy beside it, both ways
#
# The repository goes up whole through proton's own drive cli, vendored as its prebuilt linux-x64 binary (a
# bun-compiled elf): it is encrypted, deduplicated and holds every snapshot. The cli (0.8.0) has no mirror mode (its
# folder strategies are merge, rename, replace and skip, and replace re-uploads everything), so proton-mirror.sh diffs
# the upload against the previous run's manifest and prunes what vanished, trash and all (proton never empties it, and
# trash counts against the quota); its header says how. To start it over, trash its remote folder and delete its
# manifest.
#
# Of the raw trees only the syncthing folder goes up, browsable in proton drive (which encrypts end to end itself) and
# editable there: an edit on the web or the phone comes back to the folder within the hour, and syncthing takes it to
# the owner's devices. It runs on the same cli, which lists, uploads, downloads and trashes; proton-bisync.py's header
# says how (rclone's protondrive backend cannot sign in: proton asks it for a captcha it cannot solve). Its history is
# the repository's. A file the sync deletes on proton lands in proton's trash, which stays until the owner empties it;
# one it deletes here waits in proton-bisync-trash beside the folder for a month.
#
# Retention: prometheus and loki compact, rewriting their blocks, so every snapshot pins fresh copies for up to two
# years. Loki keeps 14 days of logs, so its tree is not backed up; prometheus keeps 10 years, so it is a source of
# its own with a short retention. Registry images are rebuilt from git by ci.
#
# Verification: kopia-verify re-reads a share of the stored files every week and downloads a few repository blobs
# back from proton drive, comparing them with the local ones; each part publishes its own freshness metric.
#
# A proton outage (modules/upstream) skips the night's upload or sample: the off-site copy stays as it was.
{ config, lib, pkgs, catalog, site, inventory, lab, nasClients, upstream, ... }:
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
  # the syncthing folder main.nix declares, synced with offsiteRoot/<its name>; none in a test that has no use for it
  shareDir = config.services.syncthing.settings.folders.sync.path or null;
  # after the 02:00 snapshot
  repoSyncAt = "04:00";
  repoSyncDelay = "30m";
  # proton-bisync: the owner's choice; a run finding the proton lock taken skips its hour
  shareSyncAt = "hourly";
  shareSyncDelay = "5m";
  # an hourly run moves what changed in an hour; past this it hangs. No overlap: the timer leaves a running unit be
  shareSyncTimeout = "6h";
  # the baseline reads every remote folder (~7 h for the 13k of 2026-10) and copies whatever one side lacks; one cut
  # short resumes with what is left: rerun it until it succeeds
  shareResyncTimeout = "20h";
  # an hourly run reads remote folders, the longest unread first, this long: the whole tree about every 11 runs
  shareSweepSeconds = 40 * 60;
  # a run may prune this much of what the repository mirror uploaded: maintenance drops a few percent a night; more is
  # a local loss the off-site copy exists to survive
  repoGoneMaxPercent = 50;
  # a sync run may delete this much of either side: a share loses a folder now and then; more is a loss on one side
  # the other must not take over
  shareMaxDeletePercent = 20;
  bisyncDir = "/var/lib/proton-bisync";
  # who owns the folder's files: downloads land as syncthing writes
  shareOwner = { inherit (config.services.syncthing) user group; };
  # a conflict's proton version: notes.txt -> notes.proton-conflict.txt
  shareConflictSuffix = "proton-conflict";
  # files the sync deletes here wait beside the folder, on its file system, this long
  shareTrashDays = 30;
  # syncthing's own stay local: the folder marker, file versions, and temp files of a pull in progress (unix and
  # windows names); name patterns, a folder's matching its whole subtree
  shareExcludes = [ ".stfolder" ".stversions" ".syncthing.*.tmp" "~syncthing~*.tmp" ];
  probeProton = pkgs.writeShellScript "proton-probe" "exec ${upstream.run} proton";
  protonMirror = import ./proton-mirror.nix { inherit pkgs; };
  protonBisync = import ./proton-bisync.nix { inherit pkgs; };
  # publishes an off-site copy's success time as homelab_offsite_last_success_timestamp_seconds{mirror="<label>"} in
  # <textfile>.prom
  offsiteMetric = { label, textfile }: pkgs.writeShellScript "${textfile}-metric" "exec ${metricWrite} ${lib.escapeShellArgs [
    textfile "homelab_offsite_last_success_timestamp_seconds" "Unix time of the last Proton Drive mirror run."
  ]} \"$1\" ${lib.escapeShellArg "{mirror=\"${label}\"}"}";
  shareMetric = { label = "share"; textfile = "proton_bisync"; };
  # an off-site run: a oneshot under the proton lock that skips a proton outage
  offsiteUnit = { description, timeout, exec, environment }: {
    inherit description environment;
    after = [ "network-online.target" "remote-fs.target" ];
    wants = [ "network-online.target" ];
    # never restart on a nixos switch: a multi-hour run would block the whole deploy; the timer picks up changes
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = timeout;
      # 1.8G peak on 2026-10-01; above that it is a leak, and nfs and smb keep the rest of the 3G guest
      MemoryMax = "2G";
      SuccessExitStatus = [ upstream.unavailable ];
      CPUWeight = "idle";
      IOSchedulingClass = "idle";
      ExecStart = exec;
    };
  };
  offsiteTimer = { at, delay }: {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = at; Persistent = true; RandomizedDelaySec = delay; };
  };
  # proton-bisync.sh's environment, and its engine's (proton-bisync.py)
  bisyncEnv = protonEnv // {
    PROTON_BISYNC_SOURCE = shareDir;
    PROTON_BISYNC_MARKER = ".stfolder";
    PROTON_BISYNC_REMOTE = "${offsiteRoot}/${baseNameOf shareDir}";
    PROTON_BISYNC_STATE = bisyncDir;
    PROTON_BISYNC_SESSION = "${protonDir}/auth-session.json";
    PROTON_BISYNC_EXCLUDES = toString shareExcludes;
    PROTON_BISYNC_MAX_DELETE_PERCENT = toString shareMaxDeletePercent;
    PROTON_BISYNC_CONFLICT_SUFFIX = shareConflictSuffix;
    PROTON_BISYNC_TRASH = "${dirOf shareDir}/proton-bisync-trash";
    PROTON_BISYNC_TRASH_DAYS = toString shareTrashDays;
    PROTON_BISYNC_SWEEP_SECONDS = toString shareSweepSeconds;
    PROTON_BISYNC_OWNER = "${shareOwner.user}:${shareOwner.group}";
    PROTON_BISYNC_CLI = "${protonDriveCli}/bin/proton-drive";
    PROTON_BISYNC_LOCK = protonLock;
    PROTON_BISYNC_PROBE = probeProton;
    PROTON_BISYNC_METRIC = offsiteMetric shareMetric;
  };
  # the cli holds a downloaded file's ciphertext in memory: a 1.65G drone video ran the ballooned guest (2.5G) out of
  # memory on 2026-10-13, an nfsd allocation set off the kill. The cap keeps the oom kill in this unit, and the engine
  # outlives its cli call, so only that file fails and the run goes on (proton-bisync.py `fail`)
  bisyncUnit = { description, mode, timeout }: lib.recursiveUpdate (offsiteUnit {
    inherit description timeout;
    exec = "${lib.getExe protonBisync} ${mode}";
    environment = bisyncEnv;
  }) { serviceConfig = { MemoryMax = "1536M"; OOMPolicy = "continue"; }; };
  # every guest's local state copy (modules/local-state), "<share name> <guest> <address>" per line: the exported ones
  # (nasClients, a test nas's own) and a powered-off guest's (lab.shares), whose seed takes the restore once powered
  idAt = ip: lib.findFirst (id: inventory.${id}.ip == ip) (throw "kopia: no guest at ${ip}") (lib.attrNames inventory);
  localStateLines = id: shares: map (s: "${lib.removePrefix "${source}/data/" s.path} vm-${id} ${inventory.${id}.ip}\n")
    (lib.filter (s: s.localState) shares);
  localStates = pkgs.writeText "local-states" (lib.concatStrings (lib.unique (lib.concatLists
    (lib.mapAttrsToList localStateLines lab.shares ++ lib.mapAttrsToList (ip: localStateLines (idAt ip)) nasClients))));
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
  homelab.textfiles = [ "nas_backup" "proton_sync" shareMetric.textfile "backup_verify_repository" "backup_verify_offsite" ];

  sops.secrets = {
    kopia-password = {};
    # the web ui's basic auth (user kopia) behind authelia: the port stays closed to whoever else reaches it
    kopia-server-password = {};
  };

  environment.systemPackages = [ kopiaWrapper restoreScript protonDriveCli protonLogin ];

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 root root -"
    "d ${logDir} 0700 root root -"
    "d ${cacheDir} 0700 root root -"
    # the proton session, written by the one-time login and refreshed by proton-sync
    "d ${protonDir} 0700 root root -"
  ] ++ lib.optional (shareDir != null)
    # the sync's state (proton-bisync.py): the agreed snapshot of both sides
    "d ${bisyncDir} 0700 root root -";

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

  # the repository shares the data's disk; the header says how the mirror works
  systemd.services.proton-sync = offsiteUnit {
    description = "Mirror the Kopia repository to Proton Drive";
    # first run uploads everything; unchanged files are content-skipped on later runs
    timeout = "12h";
    exec = lib.getExe protonMirror;
    environment = protonEnv // {
      PROTON_MIRROR_SOURCE = repo;
      PROTON_MIRROR_TARGET = offsiteRepoParent;
      PROTON_MIRROR_ROOT = offsiteRoot;
      PROTON_MIRROR_ROOT_KEEP = toString ([ (baseNameOf offsiteRepoParent) ] ++ lib.optional (shareDir != null) (baseNameOf shareDir));
      PROTON_MIRROR_MARKER = "kopia.repository.f";
      PROTON_MIRROR_MANIFEST = manifest;
      PROTON_MIRROR_MAX_GONE_PERCENT = toString repoGoneMaxPercent;
      PROTON_MIRROR_STATE = protonDir;
      PROTON_MIRROR_LOCK = protonLock;
      PROTON_MIRROR_PROBE = probeProton;
      PROTON_MIRROR_METRIC = offsiteMetric { label = "kopia"; textfile = "proton_sync"; };
    };
  } // { path = [ protonDriveCli ]; };
  systemd.timers.proton-sync = offsiteTimer { at = repoSyncAt; delay = repoSyncDelay; };

  # the header says what it syncs, proton-bisync.py how
  systemd.services.proton-bisync = lib.mkIf (shareDir != null) (lib.recursiveUpdate (bisyncUnit {
    description = "Sync the Syncthing folder with Proton Drive both ways";
    mode = "sync";
    timeout = shareSyncTimeout;
  }) {
    # a share that never synced (no session, no baseline) reads as stale for the offsite_stale alert, not as absent
    serviceConfig.ExecStartPre = pkgs.writeShellScript "proton-bisync-seed" ''
      [ -e ${config.homelab.textfileDir}/${shareMetric.textfile}.prom ] || exec ${offsiteMetric shareMetric} 0
    '';
  });
  systemd.timers.proton-bisync = lib.mkIf (shareDir != null) (offsiteTimer { at = shareSyncAt; delay = shareSyncDelay; });
  # by hand only: the baseline decides what both sides hold (proton-bisync.py, README.md Off-site)
  systemd.services.proton-bisync-resync = lib.mkIf (shareDir != null) (bisyncUnit {
    description = "Lay the baseline of the Syncthing folder's sync with Proton Drive";
    mode = "resync";
    timeout = shareResyncTimeout;
  });

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
