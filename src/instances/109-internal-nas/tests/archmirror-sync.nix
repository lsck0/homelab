# T11: vm-109's arch mirror sync (lib/archmirror-sync.sh, the unit's own derivation) against a local rsync daemon
# in the build sandbox: first sync, the lastupdate short-circuit (by content, not mtime), an upstream change, an
# unreachable upstream, and a transfer cut mid-file by killing the daemon, which must leave the served tree and its
# stamp untouched and converge on the next run. The expected trees are stated here, not derived from the script.
{ pkgs, lib, ... }:
let
  sync = import ../lib/archmirror-sync.nix { inherit pkgs; };
  port = 8730;
  module = "archlinux";
  # slow enough that the cut lands mid-file, fast enough to keep the test short: 40 MiB take 20 s at 2 MiB/s
  slowKBps = 2048;
  # unlimited for the passes that must finish
  fastKBps = 1024 * 1024;
  bigMiB = 40;
  # the cut comes once this much of the big file has arrived
  cutKiB = 2048;
  # bounded waits; each poll is a tenth of a second
  daemonUpPolls = 300;
  cutPolls = 600;
in
pkgs.runCommand "archmirror-sync" {
  nativeBuildInputs = [ sync pkgs.rsync pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.util-linux pkgs.gnugrep ];
} ''
  set -euo pipefail
  W=$PWD
  U=$W/upstream
  T=$W/target
  XFER=$W/xfer.log
  export ARCHMIRROR_UPSTREAM=rsync://127.0.0.1:${toString port}/${module}/
  export ARCHMIRROR_TARGET=$T
  export ARCHMIRROR_BWLIMIT_KBPS=${toString fastKBps}

  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }

  # -----------------------------------------------------------------------------
  # UPSTREAM: an rsync daemon in its own process group, so a kill takes the forked transfer child too
  cat > rsyncd.conf <<EOF
  use chroot = no
  # a real mirror serves its relative links as they are; without chroot rsync would munge them
  munge symlinks = no
  log file = $XFER
  transfer logging = yes
  log format = %o %f
  [${module}]
    path = $U
    read only = yes
  EOF
  daemon_start() {
    setsid rsync --daemon --no-detach --address 127.0.0.1 --port ${toString port} --config rsyncd.conf &
    daemon=$!
    for _ in $(seq ${toString daemonUpPolls}); do
      rsync --no-motd rsync://127.0.0.1:${toString port}/ >/dev/null 2>&1 && return 0
      sleep 0.1
    done
    fail "rsync daemon did not come up"
  }
  # rsync exits 20 on the signal
  daemon_stop() { kill -- "-$daemon"; wait "$daemon" || [ $? = 20 ]; }

  # every file and link of a tree outside .~tmp~ staging, with its content hash or link target
  manifest() {
    (cd "$1" && find . -path '*/.~tmp~' -prune -o \( -type f -o -type l \) -print | sort | while read -r p; do
      if [ -L "$p" ]; then echo "$p -> $(readlink "$p")"; else echo "$p $(sha256sum < "$p" | cut -d' ' -f1)"; fi
    done)
  }
  # the policy: the mirror is upstream minus /iso, /sources and links that leave the tree
  expected() { manifest "$U" | grep -vE '^\./(iso|sources)/|^\./extra/os/x86_64/evil '; }
  staging_left() { find "$T" -name '.~tmp~' | grep -q .; }
  sends() { grep -c ' send ' "$XFER"; }

  mkdir -p "$U"/core/os/x86_64 "$U"/extra/os/x86_64 "$U"/pool/packages "$U"/iso "$U"/sources
  echo 1000 > "$U"/lastupdate
  echo core-db-1 > "$U"/core/os/x86_64/core.db
  echo a-1 > "$U"/core/os/x86_64/a-1.pkg.tar.zst
  echo b-1 > "$U"/pool/packages/b-1.pkg.tar.zst
  ln -s ../../../pool/packages/b-1.pkg.tar.zst "$U"/extra/os/x86_64/b-1.pkg.tar.zst
  ln -s /etc/passwd "$U"/extra/os/x86_64/evil
  head -c 1M /dev/zero > "$U"/iso/big.iso
  echo x > "$U"/sources/x
  daemon_start

  # -----------------------------------------------------------------------------
  # 1. FIRST RUN
  archmirror-sync
  [ "$(manifest "$T")" = "$(expected)" ] || { diff <(manifest "$T") <(expected) >&2; fail "first run: tree differs from the policy"; }
  [ -L "$T"/extra/os/x86_64/b-1.pkg.tar.zst ] || fail "first run: the relative pool link is no link"
  [ ! -e "$T"/extra/os/x86_64/evil ] && [ ! -L "$T"/extra/os/x86_64/evil ] || fail "first run: the escaping link was copied"
  cmp -s "$U"/lastupdate "$T"/lastupdate || fail "first run: lastupdate differs"
  staging_left && fail "first run: .~tmp~ left behind"
  pass "first run mirrors upstream minus iso, sources and escaping links"

  # -----------------------------------------------------------------------------
  # 2. UNCHANGED UPSTREAM: one stamp transfer, no full pass (a file deleted locally stays deleted)
  rm "$T"/core/os/x86_64/core.db
  before=$(sends)
  said=$(archmirror-sync)
  echo "$said" | grep -q "upstream unchanged" || fail "unchanged: no short-circuit ($said)"
  [ "$(( $(sends) - before ))" = 1 ] && grep ' send ' "$XFER" | tail -1 | grep -qE '[ /]lastupdate$' \
    || fail "unchanged: transferred more than lastupdate: $(grep ' send ' "$XFER" | tail -n +$((before + 1)))"
  [ ! -e "$T"/core/os/x86_64/core.db ] || fail "unchanged: the full pass ran"
  pass "unchanged upstream costs one lastupdate transfer"

  # -----------------------------------------------------------------------------
  # 3. THE SHORT-CIRCUIT COMPARES CONTENT: a new mtime with the same bytes is no change
  touch -d '2030-01-01' "$U"/lastupdate
  said=$(archmirror-sync)
  echo "$said" | grep -q "upstream unchanged" || fail "mtime: a touched lastupdate forced a full pass ($said)"
  pass "lastupdate is compared by content"

  # -----------------------------------------------------------------------------
  # 4. UPSTREAM CHANGED: a-2 in, a-1 out, the locally deleted core.db back
  echo 1001 > "$U"/lastupdate
  echo a-2 > "$U"/core/os/x86_64/a-2.pkg.tar.zst
  rm "$U"/core/os/x86_64/a-1.pkg.tar.zst
  archmirror-sync
  [ "$(manifest "$T")" = "$(expected)" ] || { diff <(manifest "$T") <(expected) >&2; fail "changed: tree differs"; }
  [ -e "$T"/core/os/x86_64/a-2.pkg.tar.zst ] && [ ! -e "$T"/core/os/x86_64/a-1.pkg.tar.zst ] || fail "changed: a-1/a-2"
  staging_left && fail "changed: .~tmp~ left behind"
  pass "a changed upstream is mirrored, stale files deleted, no staging left"

  # -----------------------------------------------------------------------------
  # 5. UPSTREAM UNREACHABLE: fails, touches nothing
  daemon_stop
  served=$(manifest "$T")
  if archmirror-sync; then fail "unreachable: exit 0"; fi
  [ "$(manifest "$T")" = "$served" ] || fail "unreachable: the tree changed"
  pass "an unreachable upstream fails and leaves the mirror alone"

  # -----------------------------------------------------------------------------
  # 6. TRANSFER CUT MID-FILE: the served tree and its old stamp survive, the next run converges
  echo 1002 > "$U"/lastupdate
  head -c ${toString bigMiB}M /dev/zero > "$U"/extra/os/x86_64/big-1.pkg.tar.zst
  daemon_start
  ARCHMIRROR_BWLIMIT_KBPS=${toString slowKBps} archmirror-sync > cut.log 2>&1 &
  client=$!
  arrived=0
  for _ in $(seq ${toString cutPolls}); do
    if find "$T" -name '*big-1.pkg.tar.zst*' -size +${toString cutKiB}k | grep -q .; then arrived=1; break; fi
    sleep 0.1
  done
  [ "$arrived" = 1 ] || fail "cut: the big file never started arriving"
  daemon_stop
  if wait "$client"; then fail "cut: exit 0 after the daemon died mid-file"; fi
  [ "$(manifest "$T")" = "$served" ] || { diff <(manifest "$T") <(echo "$served") >&2; fail "cut: the served tree changed"; }
  [ "$(cat "$T"/lastupdate)" = 1001 ] || fail "cut: the stamp moved, the next run would short-circuit"
  daemon_start
  archmirror-sync
  [ "$(manifest "$T")" = "$(expected)" ] || { diff <(manifest "$T") <(expected) >&2; fail "cut: no convergence"; }
  staging_left && fail "cut: .~tmp~ left behind after the converging run"
  pass "a cut transfer leaves tree and stamp alone, the next run converges"

  daemon_stop
  touch $out
''
