# vm-104's off-site copies (lib/proton-mirror.nu, the units' own derivation) against the fake proton-drive cli
# (lib/fake-proton-drive.nix), its drive a folder of the build sandbox. The kopia repository's mirror: upload and prune
# for good, the stray trees of earlier versions deleted while the syncthing folder's and cold storage's copies stay,
# the mass-deletion guard and its override, a missing, unmarked or empty repository, an outage, no session, a failed
# upload, a torn events.lock. Cold storage's upload: a folder without a file is refused until it is filled, new and
# changed files go up, a file deleted or a folder emptied here stays remote, a failed upload or an outage reports no
# success. Paths the cli would read as globs (the fake's too: {GUID} folders, name[0] files) go up escaped, any other
# (a (1).txt, @scope) as it is.
{ pkgs, lib, ... }:
let
  mirror = import ../lib/proton-mirror.nix { inherit pkgs; };
  inherit
    ((import ../../../../modules/upstream {
      inherit lib pkgs;
      lab.upstreams = { };
    })._module.args.upstream
    )
    unavailable
    ;
  fakeCli = import ./lib/fake-proton-drive.nix { inherit pkgs; };
in
pkgs.runCommand "proton-mirror"
  {
    nativeBuildInputs = [
      mirror
      fakeCli
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.diffutils
    ];
  }
  ''
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
      PROTON_MIRROR_ROOT_KEEP="BACKUPS sync cold-storage" PROTON_MIRROR_MARKER=kopia.repository.f \
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
    # runs proton-mirror in MODE, expecting the given exit status
    MODE=mirror
    run() { local want=$1 status=0; shift; env "$@" proton-mirror "$MODE" > run.log 2>&1 || status=$?
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

    # 1. FIRST RUN, behind an unclean shutdown's torn events.lock
    head -c 15 /dev/zero > "$STATE"/events.lock
    run 0
    [ ! -e "$STATE"/events.lock ] || fail "first run: the torn events.lock stayed"
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

    # 7. COLD STORAGE: one way, nothing remote ever deleted
    MODE=upload
    COLD="$W/{vol}[0]/cold-storage"
    C=$FAKE_DRIVE$ROOT/cold-storage
    UPLOADED=$STATE/cold-storage.uploaded
    cold=(PROTON_MIRROR_SOURCE="$COLD" PROTON_MIRROR_TARGET=$ROOT PROTON_MIRROR_UPLOADED="$UPLOADED")
    mkdir -p "$COLD"/island_2019
    rm metric.out
    run 1 "''${cold[@]}"
    [ ! -e "$C" ] && [ ! -e metric.out ] && [ ! -e "$UPLOADED" ] || fail "cold storage: an empty folder counted as uploaded"
    pass "a cold storage without a file is refused, with no success time and no first upload marked"

    echo photo > "$COLD"/island_2019/beach.jpg
    echo essay > "$COLD"/schule.txt
    mkdir "$COLD/{guid}"
    echo state > "$COLD/{guid}/state.rsm"
    echo zero > "$COLD/x[0].txt"
    if unescaped=$(proton-drive filesystem upload "$COLD" "$ROOT" 2>&1) || ! grep -q 'No paths matched' <<<"$unescaped"; then
      fail "the fake cli took an unescaped pattern literally"
    fi
    run 0 "''${cold[@]}"
    same "$C" "./island_2019/
    ./island_2019/beach.jpg photo
    ./schule.txt essay
    ./x[0].txt zero
    ./{guid}/
    ./{guid}/state.rsm state" "cold storage: the first upload is not the folder"
    [ -s metric.out ] && [ -e "$UPLOADED" ] || fail "cold storage: no success time or first upload marked"
    pass "once filled, cold storage goes up, glob characters in its path and names included"
    rm "$COLD"/island_2019/beach.jpg
    echo essay-v2 > "$COLD"/schule.txt
    run 0 "''${cold[@]}"
    same "$C" "./island_2019/
    ./island_2019/beach.jpg photo
    ./schule.txt essay-v2
    ./x[0].txt zero
    ./{guid}/
    ./{guid}/state.rsm state" "cold storage: a deleted file left the remote, or a changed one did not arrive"
    rm -r "$COLD"/*
    rm metric.out
    run 1 "''${cold[@]}"
    [ -e "$C"/island_2019/beach.jpg ] && [ -e "$C"/schule.txt ] && trash_empty && [ ! -e metric.out ] \
      || fail "cold storage: an emptied folder emptied the remote or reported success"
    pass "cold storage takes new and changed files; what is deleted here stays remote, nothing goes to the trash"

    MODE=mirror
    run 0
    [ -e "$C"/schule.txt ] || fail "cold storage: the repository mirror took it for a stray"
    pass "the repository mirror keeps cold storage's copy"

    MODE=upload
    echo late > "$COLD"/late.txt
    rm metric.out
    run 1 "''${cold[@]}" FAKE_UPLOAD_FAIL=1
    run ${toString unavailable} "''${cold[@]}" PROTON_MIRROR_PROBE=$W/probe-down
    [ ! -e "$C"/late.txt ] && [ ! -e metric.out ] || fail "cold storage: a failed or skipped upload reported success"
    run 0 "''${cold[@]}"
    [ -e "$C"/late.txt ] && [ -s metric.out ] || fail "cold storage: the next run did not catch up"
    pass "a failed upload or an outage reports no success; the next run catches up"

    # 8. PATHS: one without * ? [ { goes up as it is, one with them escaped
    for name in "a (1).txt" "@scope/x" "Program Files (x86)/y" "{guid}/z" "x[0]"; do
      mkdir -p "$W/paths/$name"
      echo "$name" > "$W/paths/$name/f"
      run 0 "''${cold[@]}" PROTON_MIRROR_SOURCE="$W/paths/$name" PROTON_MIRROR_TARGET=$ROOT/paths
      [ "$(cat "$FAKE_DRIVE$ROOT/paths/$(basename "$name")/f")" = "$name" ] || fail "paths: $name did not go up"
    done
    if proton-drive filesystem upload "$W/paths/a \(1\).txt" "$ROOT" 2>/dev/null; then
      fail "the fake cli unescaped a path without glob characters"
    fi
    pass "a path the cli takes literally goes up unescaped, a glob one escaped"

    touch $out
  ''
