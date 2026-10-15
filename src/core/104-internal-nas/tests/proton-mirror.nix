# vm-104's mirror of the kopia repository (lib/proton-mirror.sh, the unit's own derivation) against the fake
# proton-drive cli (lib/fake-proton-drive.nix), its drive a folder of the build sandbox: upload and prune for good,
# the stray trees of earlier versions deleted while the syncthing folder's copy stays, the mass-deletion guard and its
# override, a missing, unmarked or empty repository, an outage, no session, a failed upload. The expected trees are
# stated here.
{ pkgs, lib, ... }:
let
  mirror = import ../lib/proton-mirror.nix { inherit pkgs; };
  inherit ((import ../../../modules/upstream { inherit lib pkgs; lab.upstreams = { }; })._module.args.upstream) unavailable;
  fakeCli = import ./lib/fake-proton-drive.nix { inherit pkgs; };
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

  # 5. OUTAGE, NO SESSION: nothing pruned, no success time
  rm "$K"/xn0_2
  rm metric.out
  run ${toString unavailable} PROTON_MIRROR_PROBE=$W/probe-down
  mv "$STATE"/auth-session.json "$W"/session
  run 0
  mv "$W"/session "$STATE"/auth-session.json
  [ "$(tree "$FAKE_DRIVE")" = "$before" ] && [ ! -e metric.out ] || fail "skipped runs: the drive changed or success was reported"
  pass "an outage or a missing session prunes nothing"

  # 6. FAILED UPLOAD: the prune comes first, so a full drive still frees what the source dropped; no success time
  echo new > "$K"/p_after_full
  run 1 FAKE_UPLOAD_FAIL=1
  [ ! -e "$B"/xn0_2 ] && [ ! -e "$B"/p_after_full ] && [ ! -e metric.out ] \
    || fail "failed upload: the dropped blob stayed, the new one arrived, or success was reported"
  run 0
  [ -e "$B"/p_after_full ] && [ -s metric.out ] || fail "failed upload: the next run did not catch up"
  pass "a failed upload still prunes; the next run uploads what it missed"

  touch $out
''
