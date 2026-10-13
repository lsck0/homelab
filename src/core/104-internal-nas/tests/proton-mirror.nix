# vm-104's mirror of the kopia repository (lib/proton-mirror.sh, the unit's own derivation) against a fake
# proton-drive cli that keeps its drive in a folder of the build sandbox and, like the real one, lets same-named items
# pile up in the trash and refuses to delete an ambiguous one: upload and prune for good, the stray trees of earlier
# versions deleted while the syncthing folder's copy stays, the mass-deletion guard and its override, a missing,
# unmarked or empty repository, an outage, no session, a failed upload. The expected trees are stated here.
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
  K=$W/BACKUPS/kopia
  B=$FAKE_DRIVE$ROOT/BACKUPS/kopia
  mkdir -p "$FAKE_DRIVE/my-files" "$FAKE_DRIVE/trash" "$STATE"
  echo '{}' > "$STATE/auth-session.json"
  printf '#!/bin/sh\nexit ${toString unavailable}\n' > probe-down
  printf '#!/bin/sh\necho "$1" > %s/metric.out\n' "$W" > metric
  chmod +x probe-down metric
  export PROTON_MIRROR_SOURCE=$K PROTON_MIRROR_TARGET=$ROOT/BACKUPS PROTON_MIRROR_ROOT=$ROOT \
    PROTON_MIRROR_ROOT_KEEP="BACKUPS sync" PROTON_MIRROR_MARKER=kopia.repository.f \
    PROTON_MIRROR_MANIFEST=$STATE/offsite-manifest.txt PROTON_MIRROR_MAX_GONE_PERCENT=50 PROTON_MIRROR_STATE=$STATE \
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

  mkdir -p "$K"/p00/2ab "$K"/p00/3cd
  echo format > "$K"/kopia.repository.f
  echo pack > "$K"/p00/2ab/cdef
  echo pack2 > "$K"/p00/3cd/ef01
  echo index > "$K"/xn0_1
  # an earlier version's raw tree beside the mirrors, and the syncthing folder's copy (proton-bisync)
  mkdir -p "$FAKE_DRIVE$ROOT"/syncthing "$FAKE_DRIVE$ROOT"/sync
  echo stale > "$FAKE_DRIVE$ROOT"/syncthing/x
  echo note > "$FAKE_DRIVE$ROOT"/sync/note

  # 1. FIRST RUN
  run 0
  same "$B" "./kopia.repository.f format
  ./p00/
  ./p00/2ab/
  ./p00/2ab/cdef pack
  ./p00/3cd/
  ./p00/3cd/ef01 pack2
  ./xn0_1 index" "first run: the remote is not the repository"
  [ -e "$FAKE_DRIVE$ROOT"/sync/note ] && [ ! -e "$FAKE_DRIVE$ROOT"/syncthing ] || fail "first run: strays and kept folders"
  trash_empty || fail "first run: the stray tree is still in the trash"
  [ -s metric.out ] || fail "first run: no success time"
  pass "the repository goes up; an earlier version's tree is deleted for good, the syncthing folder's copy stays"

  # 2. PRUNE: a dropped blob, deleted for good
  rm "$K"/xn0_1
  run 0
  [ ! -e "$B"/xn0_1 ] && trash_empty || fail "prune: a dropped blob stayed"
  pass "a blob kopia dropped leaves the trash too"

  # 3. MASS DELETION: refused, then allowed once
  rm "$K"/p00/2ab/cdef "$K"/p00/3cd/ef01
  rm metric.out
  run 1
  grep -q 'allow-large' run.log || fail "guard: no hint at the override"
  [ -e "$B"/p00/2ab/cdef ] && [ ! -e metric.out ] || fail "guard: pruned or reported success"
  touch "$STATE"/offsite-manifest.txt.allow-large
  run 0
  [ ! -e "$B"/p00/2ab/cdef ] && [ ! -e "$B"/p00/3cd/ef01 ] || fail "override: the remote kept a dropped blob"
  [ ! -e "$STATE"/offsite-manifest.txt.allow-large ] || fail "override: it outlived its run"
  pass "pruning over the limit stops until allow-large is touched, which holds for one run"

  # 4. NO SOURCE: missing, unmarked (unmounted) or holding nothing but the marker
  echo back > "$K"/xn0_2
  run 0
  before=$(tree "$FAKE_DRIVE")
  mv "$K" "$W/moved"
  run 1
  mkdir "$K"
  echo pack > "$K"/p_new
  run 1
  rm "$K"/p_new
  echo format > "$K"/kopia.repository.f
  run 1
  [ "$(tree "$FAKE_DRIVE")" = "$before" ] || fail "no source: the drive changed"
  rm -r "$K"
  mv "$W/moved" "$K"
  pass "a missing, unmarked or empty repository is refused and leaves the drive alone"

  # 5. OUTAGE, NO SESSION, FAILED UPLOAD: nothing pruned, no success time
  rm "$K"/xn0_2
  rm metric.out
  run ${toString unavailable} PROTON_MIRROR_PROBE=$W/probe-down
  run 1 FAKE_UPLOAD_FAIL=1
  mv "$STATE"/auth-session.json "$W"/session
  run 0
  mv "$W"/session "$STATE"/auth-session.json
  [ "$(tree "$FAKE_DRIVE")" = "$before" ] && [ ! -e metric.out ] || fail "skipped runs: the drive changed or success was reported"
  run 0
  [ ! -e "$B"/xn0_2 ] && [ -s metric.out ] || fail "skipped runs: the next run did not catch up"
  pass "an outage, a missing session or a failed upload prune nothing; the next run catches up"

  touch $out
''
