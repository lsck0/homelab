# vm-104's proton drive mirrors (lib/proton-mirror.sh, the units' own derivation) against a fake proton-drive cli that
# keeps its drive in a folder of the build sandbox and, like the real one, lets same-named items pile up in the trash
# and refuses to delete an ambiguous one. The syncthing folder (tree): plain files minus syncthing's internals, a
# pruned subtree and same-named files deleted for good, the mass-deletion guard and its override, a missing, unmarked
# or empty source, an outage, no session, a failed upload; the kopia repository (blobs): upload and prune, the stray
# trees of earlier versions trashed while every mirror's folder stays. The expected trees are stated here.
{ pkgs, lib, ... }:
let
  mirror = import ../lib/proton-mirror.nix { inherit pkgs; };
  inherit ((import ../../../modules/upstream { inherit lib pkgs; lab.upstreams = { }; })._module.args.upstream) unavailable;
  # the drive as the cli shows it; FAKE_DRIVE is its folder, FAKE_LOG gets one line per call
  fakeCli = pkgs.writeShellApplication {
    name = "proton-drive";
    runtimeInputs = with pkgs; [ coreutils findutils jq ];
    text = ''
      echo "$*" >> "$FAKE_LOG"
      [ "$1" = filesystem ] || { echo "fake: no command $1" >&2; exit 2; }
      verb=$2
      shift 2
      local_of() { echo "$FAKE_DRIVE$1"; }
      missing() { echo "$1: Node not found" >&2; exit 1; }
      oks() { jq -n --argjson n "$1" '[range($n) | { ok: true }]'; }
      case $verb in
        list)
          [ "$1" = -j ] && shift
          [ -d "$(local_of "$1")" ] || missing "$1"
          find "$(local_of "$1")" -mindepth 1 -maxdepth 1 -printf '%f\n' | jq -R '{ name: { value: . } }' | jq -s . ;;
        create-folder)
          [ -d "$(local_of "$1")" ] || missing "$1"
          [ ! -e "$(local_of "$1/$2")" ] || { echo "$1/$2 already exists" >&2; exit 1; }
          mkdir "$(local_of "$1/$2")" ;;
        upload)
          [ -z "''${FAKE_UPLOAD_FAIL:-}" ] || { echo "fake: network down" >&2; exit 1; }
          paths=()
          while [ $# -gt 0 ]; do
            case $1 in -f|-d) shift 2 ;; -j|-t) shift ;; *) paths+=("$1"); shift ;; esac
          done
          parent=''${paths[-1]}
          unset 'paths[-1]'
          [ -d "$(local_of "$parent")" ] || missing "$parent"
          failures='[]'
          for src in "''${paths[@]}"; do
            base=$(local_of "$parent")/$(basename "$src")
            mkdir -p "$base"
            while IFS= read -r -d "" rel; do
              if [ -d "$src/$rel" ] && [ ! -L "$src/$rel" ]; then mkdir -p "$base/$rel"
              elif [ -f "$src/$rel" ] && [ ! -L "$src/$rel" ]; then cp "$src/$rel" "$base/$rel"
              else failures=$(jq -c --arg p "$rel" '. + [{ path: $p, error: "Not a regular file or directory" }]' <<<"$failures")
              fi
            done < <(find "$src" -mindepth 1 -printf '%P\0')
          done
          echo "uploading ..."
          jq -c -n --argjson f "$failures" '{ failures: $f }'
          [ "$failures" = '[]' ] ;;
        rename)
          [ -e "$(local_of "$1")" ] || missing "$1"
          mv "$(local_of "$1")" "$(dirname "$(local_of "$1")")/$2" ;;
        trash)
          [ "$1" = -j ] && shift
          for p in "$@"; do [ -e "$(local_of "$p")" ] || missing "$p"; done
          for p in "$@"; do
            slot=$FAKE_DRIVE/trash/$(basename "$p")
            mkdir -p "$slot"
            mv "$(local_of "$p")" "$slot/$(find "$slot" -mindepth 1 -maxdepth 1 | wc -l)"
          done
          oks $# ;;
        delete)
          [ "$1" = -j ] && shift
          for p in "$@"; do
            slot=$(local_of "$p")
            [ -d "$slot" ] || { echo "$p: Trashed node not found" >&2; exit 1; }
            [ "$(find "$slot" -mindepth 1 -maxdepth 1 | wc -l)" = 1 ] || { echo "$p: name conflicts with other nodes" >&2; exit 1; }
          done
          for p in "$@"; do rm -rf "$(local_of "$p")"; done
          oks $# ;;
        *) echo "fake: no verb $verb" >&2; exit 2 ;;
      esac
    '';
  };
in
pkgs.runCommand "proton-mirror" {
  nativeBuildInputs = [ mirror fakeCli pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.diffutils ];
} ''
  set -euo pipefail
  W=$PWD
  export FAKE_DRIVE=$W/drive FAKE_LOG=$W/calls.log
  STATE=$W/state
  ROOT=/my-files/homelab-offsite
  mkdir -p "$FAKE_DRIVE/my-files" "$FAKE_DRIVE/trash" "$STATE"
  echo '{}' > "$STATE/auth-session.json"
  printf '#!/bin/sh\nexit ${toString unavailable}\n' > probe-down
  printf '#!/bin/sh\necho "$1" > %s/metric.out\n' "$W" > metric
  chmod +x probe-down metric
  export PROTON_MIRROR_ROOT=$ROOT PROTON_MIRROR_ROOT_KEEP="BACKUPS sync" PROTON_MIRROR_STATE=$STATE \
    PROTON_MIRROR_LOCK=$W/lock PROTON_MIRROR_PROBE=true PROTON_MIRROR_METRIC=$W/metric

  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }
  # every file and folder of a tree with its content
  tree() { (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
    if [ -d "$p" ]; then echo "$p/"; else echo "$p $(cat "$p")"; fi
  done); }
  same() { [ "$(tree "$1")" = "$2" ] || { diff <(tree "$1") <(echo "$2") >&2; fail "$3"; }; }
  trash_empty() { [ -z "$(ls -A "$FAKE_DRIVE/trash")" ] && [ ! -s "$STATE/offsite-purge.txt" ]; }
  # runs the mirror, expecting the given exit status
  run() { local want=$1 status=0; shift; env "$@" proton-mirror > run.log 2>&1 || status=$?
    cat run.log; [ "$status" = "$want" ] || fail "exit $status, not $want"; }

  # -----------------------------------------------------------------------------
  # SYNCTHING FOLDER (tree)
  S=$W/share/sync
  R=$FAKE_DRIVE$ROOT/sync
  tree_env=(PROTON_MIRROR_MODE=tree PROTON_MIRROR_SOURCE=$S PROTON_MIRROR_TARGET=$ROOT PROTON_MIRROR_MARKER=.stfolder
    PROTON_MIRROR_MANIFEST=$STATE/share-manifest.txt PROTON_MIRROR_MAX_GONE_PERCENT=50
    "PROTON_MIRROR_EXCLUDES=.stfolder .stversions .syncthing.*.tmp ~syncthing~*.tmp")
  mkdir -p "$S"/.stfolder "$S"/.stversions "$S"/docs/sub "$S"/notes
  echo ignore > "$S"/.stignore
  echo a > "$S"/a.txt
  echo spaced > "$S/with space.txt"
  echo docs > "$S"/docs/README
  echo sub > "$S"/docs/sub/README
  echo notes > "$S"/notes/README
  echo old > "$S"/.stversions/a~20261001.txt
  echo pulling > "$S"/docs/.syncthing.b.txt.tmp
  echo pulling > "$S"/notes/~syncthing~c.txt.tmp
  ln -s a.txt "$S"/link
  # an earlier version's raw tree beside the mirrors, and the repository's folder
  mkdir -p "$FAKE_DRIVE$ROOT"/syncthing "$FAKE_DRIVE$ROOT"/BACKUPS
  echo stale > "$FAKE_DRIVE$ROOT"/syncthing/x

  # 1. FIRST RUN
  run 0 "''${tree_env[@]}"
  same "$R" "./.stignore ignore
  ./a.txt a
  ./docs/
  ./docs/README docs
  ./docs/sub/
  ./docs/sub/README sub
  ./notes/
  ./notes/README notes
  ./with space.txt spaced" "first run: the remote is not the folder minus syncthing's internals"
  [ -d "$FAKE_DRIVE$ROOT"/BACKUPS ] && [ ! -e "$FAKE_DRIVE$ROOT"/syncthing ] || fail "first run: strays and kept folders"
  trash_empty || fail "first run: the stray tree is still in the trash"
  [ -s metric.out ] || fail "first run: no success time"
  [ ! -e "$STATE"/stage/sync ] || fail "first run: the stage was left behind"
  pass "plain files go up minus .stfolder, .stversions and temp files; an earlier version's tree is deleted for good"

  # 2. PRUNE: a whole folder, and two files of the same name, deleted for good
  rm -r "$S"/docs/sub "$S"/docs/README "$S"/notes/README
  : > "$FAKE_LOG"
  run 0 "''${tree_env[@]}"
  same "$R" "./.stignore ignore
  ./a.txt a
  ./docs/
  ./notes/
  ./with space.txt spaced" "prune: the remote kept a deleted entry"
  trash_empty || fail "prune: deleted entries left in the trash ($(ls -R "$FAKE_DRIVE"/trash))"
  [ "$(grep -c '^filesystem rename' "$FAKE_LOG")" = 3 ] || fail "prune: not one rename per topmost entry: $(grep rename "$FAKE_LOG")"
  pass "a vanished folder goes as one item, same-named files leave the trash too"

  # 3. MASS DELETION: refused, then allowed once
  rm "$S"/a.txt "$S/with space.txt" "$S"/.stignore
  rm metric.out
  run 1 "''${tree_env[@]}"
  grep -q 'allow-large' run.log || fail "guard: no hint at the override"
  [ -e "$R"/a.txt ] && [ ! -e metric.out ] || fail "guard: pruned or reported success"
  touch "$STATE"/share-manifest.txt.allow-large
  run 0 "''${tree_env[@]}"
  same "$R" "./docs/
  ./notes/" "override: the remote kept a deleted entry"
  [ ! -e "$STATE"/share-manifest.txt.allow-large ] || fail "override: it outlived its run"
  pass "pruning over the share stops until allow-large is touched, which holds for one run"

  # 4. NO SOURCE: missing, unmarked (unmounted) or holding nothing but the marker
  echo back > "$S"/docs/back.txt
  run 0 "''${tree_env[@]}"
  before=$(tree "$FAKE_DRIVE")
  mv "$S" "$W/share/moved"
  run 1 "''${tree_env[@]}"
  mkdir "$S"
  run 1 "''${tree_env[@]}"
  mkdir "$S"/.stfolder
  run 1 "''${tree_env[@]}"
  [ "$(tree "$FAKE_DRIVE")" = "$before" ] || fail "no source: the drive changed"
  rm -r "$S"
  mv "$W/share/moved" "$S"
  pass "a missing, unmarked or empty folder is refused and leaves the drive alone"

  # 5. OUTAGE, NO SESSION, FAILED UPLOAD: nothing pruned, no success time
  rm "$S"/docs/back.txt
  rm metric.out
  run ${toString unavailable} "''${tree_env[@]}" PROTON_MIRROR_PROBE=$W/probe-down
  run 1 "''${tree_env[@]}" FAKE_UPLOAD_FAIL=1
  mv "$STATE"/auth-session.json "$W"/session
  run 0 "''${tree_env[@]}"
  mv "$W"/session "$STATE"/auth-session.json
  [ "$(tree "$FAKE_DRIVE")" = "$before" ] && [ ! -e metric.out ] || fail "skipped runs: the drive changed or success was reported"
  run 0 "''${tree_env[@]}"
  [ ! -e "$R"/docs/back.txt ] && [ -s metric.out ] || fail "skipped runs: the next run did not catch up"
  pass "an outage, a missing session or a failed upload prune nothing; the next run catches up"

  # -----------------------------------------------------------------------------
  # KOPIA REPOSITORY (blobs)
  K=$W/BACKUPS/kopia
  B=$FAKE_DRIVE$ROOT/BACKUPS/kopia
  blobs_env=(PROTON_MIRROR_MODE=blobs PROTON_MIRROR_SOURCE=$K PROTON_MIRROR_TARGET=$ROOT/BACKUPS
    PROTON_MIRROR_MARKER=kopia.repository.f PROTON_MIRROR_MANIFEST=$STATE/offsite-manifest.txt PROTON_MIRROR_MAX_GONE_PERCENT=50)
  mkdir -p "$K"/p00/2ab
  echo format > "$K"/kopia.repository.f
  echo pack > "$K"/p00/2ab/cdef
  echo index > "$K"/xn0_1
  run 0 "''${blobs_env[@]}"
  same "$B" "./kopia.repository.f format
  ./p00/
  ./p00/2ab/
  ./p00/2ab/cdef pack
  ./xn0_1 index" "blobs: the remote is not the repository"
  [ -e "$R"/docs ] || fail "blobs: the syncthing mirror was taken for a stray"
  rm "$K"/xn0_1
  run 0 "''${blobs_env[@]}"
  [ ! -e "$B"/xn0_1 ] && trash_empty || fail "blobs: a dropped blob stayed"
  rm "$K"/kopia.repository.f
  run 1 "''${blobs_env[@]}"
  [ -e "$B"/p00/2ab/cdef ] || fail "blobs: an unmarked repository pruned"
  pass "the repository goes up and drops what kopia dropped, refuses without its format blob, leaves the share alone"

  touch $out
''
