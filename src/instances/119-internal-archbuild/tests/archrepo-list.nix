# vm-119's package list (lib/archrepo-list.sh) against a fixture arch-dotfiles tree in the modules layout: the
# packages.txt of every module, comments, blanks and trailing whitespace dropped, duplicates across modules and
# platforms merged, every platform's EXTRA_PACKAGES joined; nested packages.txt, flatpacks.txt and nixpkgs.txt left
# out. A bad name, an unreadable manifest, a platform file that does not source, an empty set and an old-layout
# checkout each fail the whole list and print nothing: the build prunes what the list misses.
#
# Then the completeness gate as tables: which listed names a sync db does not provide (a name, a provides with its
# version dropped and a group count; a depends and a near name do not), and publish's verdict (lib/archrepo-build.sh
# completeness_check) over served and proposed dbs: a served name the night would lose holds it back, a never-built
# one publishes and stays reported as missing.
{ pkgs, lib, ... }:
let
  list = ../lib/archrepo-list.sh;
  build = ../lib/archrepo-build.sh;
in
pkgs.runCommand "archrepo-list" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.gnugrep pkgs.libarchive pkgs.findutils ];
} ''
  set -euo pipefail
  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }

  good=$PWD/good
  mkdir -p "$good"/configs/{base/btop,desktop,programming,docs} "$good/platforms" "$good/mirror/pkgbuilds/local-recipe"
  cat > "$good/configs/base/packages.txt" <<'EOF'
  # base module: a header comment

  base                              # Arch base group
  base-devel
  libc++                            # a name with +
  trailing-space   ${"\t"}
  shared                            # also in desktop
  EOF
  # a config dir inside a module, not a module of its own
  echo nested-not-a-module > "$good/configs/base/btop/packages.txt"
  printf '%s\n' shared desktop-only '${"\t"}# an indented comment' > "$good/configs/desktop/packages.txt"
  echo org.example.FlatpakOnly > "$good/configs/desktop/flatpacks.txt"
  printf '%s\n' rust extra-dup > "$good/configs/programming/packages.txt"
  echo nixpkg-only > "$good/configs/programming/nixpkgs.txt"
  echo "a module without packages" > "$good/configs/docs/README.md"
  printf '%s\n' 'HOSTNAME=pc' 'FORM_FACTOR=desktop' 'EXTRA_PACKAGES=(pc-extra extra-dup)' 'PKG_GROUPS=(base desktop)' \
    > "$good/platforms/pc.sh"
  printf '%s\n' 'HOSTNAME=notebook' 'EXTRA_PACKAGES=(notebook-extra)' > "$good/platforms/notebook.sh"
  printf '%s\n' 'HOSTNAME=wsl' 'PKG_GROUPS=(base programming)' > "$good/platforms/wsl.sh"
  echo 'pkgname=local-recipe' > "$good/mirror/pkgbuilds/local-recipe/PKGBUILD"

  bash ${list} "$good" > got
  printf '%s\n' base base-devel desktop-only extra-dup libc++ notebook-extra pc-extra rust shared trailing-space > want
  diff -u want got || fail "the list of the good tree"
  pass "every module's packages.txt and every platform's EXTRA_PACKAGES, sorted and unique"

  # <tree> <stderr fragment> <case>: refused, nothing printed, the reason named
  expect_fail() {
    if bash ${list} "$1" > out 2> err; then fail "$3: accepted"; fi
    [ ! -s out ] || fail "$3: printed a partial list: $(head -3 out)"
    grep -qF -- "$2" err || fail "$3: message '$(cat err)' lacks '$2'"
    pass "$3"
  }
  # <name>: a fresh copy of the good tree
  variant() { rm -rf "$1"; cp -r "$good" "$1"; echo "$PWD/$1"; }

  tree=$(variant upper)
  echo 'Upper-Case' >> "$tree/configs/desktop/packages.txt"
  expect_fail "$tree" "configs/desktop/packages.txt: 'Upper-Case' is not a package name" "an upper case name is refused"

  tree=$(variant two)
  echo 'two names' >> "$tree/configs/base/packages.txt"
  expect_fail "$tree" "'two names' is not a package name" "two names on one line are refused"

  tree=$(variant indented)
  echo '  indented' >> "$tree/configs/base/packages.txt"
  expect_fail "$tree" "'  indented' is not a package name" "a name install.sh would pass with leading blanks is refused"

  tree=$(variant extra)
  echo 'EXTRA_PACKAGES=(-leading)' >> "$tree/platforms/notebook.sh"
  expect_fail "$tree" "platforms/notebook.sh: '-leading' is not a package name" "a bad EXTRA_PACKAGES entry is refused"

  tree=$(variant dangling)
  rm "$tree/configs/desktop/packages.txt"
  ln -s missing.txt "$tree/configs/desktop/packages.txt"
  expect_fail "$tree" "cannot read $tree/configs/desktop/packages.txt" "an unreadable manifest is refused"

  tree=$(variant syntax)
  echo 'EXTRA_PACKAGES=(' >> "$tree/platforms/pc.sh"
  expect_fail "$tree" "cannot source $tree/platforms/pc.sh" "a platform file that does not source is refused"

  tree=$(variant empty)
  for file in "$tree"/configs/*/packages.txt; do echo '# nothing yet' > "$file"; done
  rm "$tree/platforms/pc.sh" "$tree/platforms/notebook.sh"
  expect_fail "$tree" "no package names in $tree" "an empty set is refused"

  # the layout before the module move: the arrays lived in install.sh, no module has a packages.txt
  old=$PWD/old
  mkdir -p "$old/configs/pacman" "$old/platforms"
  printf '%s\n' 'PACKAGES=(' '    base' ')' > "$old/install.sh"
  echo key > "$old/configs/pacman/archrepo.asc"
  cp "$good/platforms/pc.sh" "$old/platforms/"
  expect_fail "$old" "no configs/<module>/packages.txt in $old" "an old-layout checkout is refused, not read as extras alone"

  # ---- the completeness gate ----
  all="base base-devel desktop-only extra-dup libc++ notebook-extra pc-extra rust shared trailing-space"
  # <name>...: the good tree's list without them, space separated
  all_but() { local name; for name in $all; do [[ " $* " == *" $name "* ]] || printf '%s ' "$name"; done; }
  # <section> <comma separated values>: one desc section, nothing for no values
  db_section() { [ -z "$2" ] || printf '%%%s%%\n%s\n\n' "$1" "$(tr ',' '\n' <<<"$2")"; }
  # <db> <entries>: a sync db as repo-add writes it; an entry is <name>/<provides>/<groups>/<depends>, lists comma separated
  db_make() {
    local db=$1 dir entry name provides groups depends
    dir=$(mktemp -d)
    for entry in $2; do
      IFS=/ read -r name provides groups depends <<<"$entry"
      mkdir "$dir/$name-1-1"
      {
        printf '%%FILENAME%%\n%s-1-1-x86_64.pkg.tar.zst\n\n%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n' "$name" "$name"
        db_section PROVIDES "$provides"
        db_section GROUPS "$groups"
        db_section DEPENDS "$depends"
      } > "$dir/$name-1-1/desc"
    done
    bsdtar -czf "$db" -C "$dir" .
  }

  # <case> <db entries> <listed names the db must miss>
  check_db() {
    db_make provided.db.tar.gz "$2"
    bash ${list} "$good" provided.db.tar.gz > got 2> err || fail "$1: refused: $(cat err)"
    [ "$(xargs < got)" = "$3" ] || fail "$1: missing '$(xargs < got)', want '$3'"
    pass "$1"
  }
  check_db "an empty db (a first run) lacks every listed name" "" "$all"
  check_db "a listed name the db has is not missing, an unlisted one is not reported" "$(all_but rust) zzz-unlisted" "rust"
  check_db "a provides counts, its version constraint dropped" "$(all_but rust) rustup/rust=1.80.0,cargo" ""
  check_db "a group counts" "$(all_but base-devel) gcc//base-devel" ""
  check_db "a depends does not count" "$(all_but rust) cargo-tools///rust" "rust"
  check_db "a near name does not count" "$(all_but rust) rust-analyzer rusty/rust-src" "rust"

  echo garbage > garbage.db.tar.gz
  if bash ${list} "$good" garbage.db.tar.gz > out 2> err; then fail "an unreadable db: accepted"; fi
  [ ! -s out ] || fail "an unreadable db: printed a partial list: $(head -3 out)"
  grep -qF "cannot read garbage.db.tar.gz" err || fail "an unreadable db: message '$(cat err)'"
  pass "an unreadable db fails the list and prints nothing"

  # <case> <served db entries, - for none> <proposed db entries> <names that hold the night back> <missing once served>
  check_gate() {
    # not served or proposed: the sourced script declares those
    local case_name=$1 served_entries=$2 proposed_entries=$3 lost_names=$4 want_missing=$5
    (
      export ARCHBUILD_COMMIT=test ARCHBUILD_RUN_STARTED=0
      # shellcheck source=/dev/null
      source ${build}
      LIST_SCRIPT=${list} DOTFILES=$good WORK=$PWD/work REPO_DIR=$PWD/served
      rm -rf "$WORK" "$REPO_DIR"
      mkdir -p "$WORK/db" "$REPO_DIR"
      [ "$served_entries" = - ] || db_make "$REPO_DIR/$REPO.db.tar.gz" "$served_entries"
      db_make "$WORK/db/$REPO.db.tar.gz" "$proposed_entries"
      # publish_main's order: the served gaps first, the gate after the db is assembled
      snapshot_missing=$(listed_missing "$REPO_DIR/$REPO.db.tar.gz")
      completeness_check > /dev/null
      want_held=
      [ -z "$lost_names" ] || want_held="listed names the served snapshot has and this one lacks: $lost_names"
      [ "$held_back" = "$want_held" ] || { echo "held back '$held_back', want '$want_held'" >&2; exit 1; }
      [ -n "$held_back" ] || snapshot_missing=$proposed_missing
      [ "$(xargs <<<"$snapshot_missing")" = "$want_missing" ] || { echo "missing '$(xargs <<<"$snapshot_missing")', want '$want_missing'" >&2; exit 1; }
    ) || fail "$case_name"
    pass "$case_name"
  }
  check_gate "a first run publishes what it has, the rest shows as missing" - "$(all_but rust)" "" "rust"
  check_gate "a never-built name does not hold the night back and stays missing" "$(all_but rust)" "$(all_but rust)" "" "rust"
  check_gate "a served name the night would lose holds it back, the served snapshot stays whole" "$all" "$(all_but rust)" "rust" ""
  check_gate "a served name kept through another package's provides is not lost" "$all" "$(all_but rust) rustup/rust" "" ""
  check_gate "only lost names hold back, the never-built one stays reported" "$(all_but pc-extra)" "$(all_but pc-extra shared)" \
    "shared" "pc-extra"
  check_gate "a night that builds a missing name clears it" "$(all_but rust)" "$all" "" ""
  touch $out
''
