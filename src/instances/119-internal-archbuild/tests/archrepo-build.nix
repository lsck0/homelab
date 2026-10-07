# single steps of vm-119's nightly build (lib/archrepo-build.sh), sourced in the sandbox.
#
# Build dependencies as a table: what build_deps_wanted installs for a recipe's .SRCINFO. A split base's packages
# depending on their siblings (apparmor.d, opentelemetry-python-contrib) must not ask the repos for them, by name or
# by provides, versioned or not; every other depends and makedepends stays, a name that only shares a prefix with a
# sibling included.
#
# The push to the mirror into a local directory: the served tree, the status and the logs status.txt names arrive,
# the final --delete keeps the logs and drops stale repo files, a stale log goes. What the build container could
# plant in the logs never leaves: a link (to the signing key here), a fifo, a directory, a file that is no .log, one
# above the size cap, a build.log that is a link, a logs/ that is a link.
{ pkgs, lib, ... }:
let
  build = ../lib/archrepo-build.sh;
in
pkgs.runCommand "archrepo-build" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.gnugrep pkgs.findutils pkgs.rsync ];
} ''
  set -euo pipefail
  export ARCHBUILD_COMMIT=test ARCHBUILD_RUN_STARTED=0
  # shellcheck source=/dev/null
  source ${build}
  # after the source, which brings a fail of its own
  fail() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }

  # ---- build dependencies ----
  # <case> <.SRCINFO lines, | separated> <wanted deps, space separated, sorted>
  check_deps() {
    local dir=$PWD/recipe
    rm -rf "$dir"
    mkdir -p "$dir"
    tr '|' '\n' <<<"$2" > "$dir/.SRCINFO"
    [ "$(build_deps_wanted "$dir" | xargs)" = "$3" ] || fail "$1: wanted '$(build_deps_wanted "$dir" | xargs)', want '$3'"
    pass "$1"
  }
  check_deps "a single package installs its depends and makedepends" \
    "pkgbase = tool|  makedepends = go|  depends = glibc|pkgname = tool" "glibc go"
  check_deps "a split meta package's siblings are not installed (apparmor.d)" \
    "pkgbase = apparmor.d|  makedepends = go|  makedepends = just|  depends = apparmor>=4.1.3|  depends = apparmor<5.0.0|pkgname = apparmor.d|  depends = apparmor|  depends = apparmor.d-base|  depends = apparmor.d-tools|pkgname = apparmor.d-base|pkgname = apparmor.d-tools" \
    "apparmor apparmor<5.0.0 apparmor>=4.1.3 go just"
  check_deps "a versioned sibling depends is not installed" \
    "pkgbase = frida|pkgname = frida|pkgname = python-frida|  depends = frida=17.18.0-2|  depends = python" "python"
  check_deps "a sibling reached through its provides is not installed (opentelemetry-python-contrib)" \
    "pkgbase = opentelemetry-python-contrib|  makedepends = python-build|pkgname = python-opentelemetry-instrumentation-openai-v2|  depends = python-opentelemetry-util-genai>=0.1|  depends = python-opentelemetry-api|pkgname = python-otel-util|  provides = python-opentelemetry-util-genai=0.2" \
    "python-build python-opentelemetry-api"
  check_deps "a name that only shares a prefix with a sibling is installed" \
    "pkgbase = apparmor.d|pkgname = apparmor.d|  depends = apparmor.d-base-extra|pkgname = apparmor.d-base" "apparmor.d-base-extra"
  check_deps "a recipe without depends installs nothing" "pkgbase = data|pkgname = data" ""

  # ---- the push to the mirror ----
  secret=SIGNING-KEY-MATERIAL
  mkdir -p run
  echo "$secret" > run/signing.asc
  PUSH_KEY_FILE=$PWD/run/push-key
  touch "$PUSH_KEY_FILE"
  LOG_PUSH_SIZE_MAX=1K

  # <public dir>: a served tree and a status page with everything the build container could plant in logs/
  fixture() {
    SERVED=$PWD/served REPO_DIR=$PWD/served/$ARCH PUBLIC=$PWD/$1 PUSH_TARGET=$PWD/mirror
    PUBLIC_LOGS=$PUBLIC/$LOGS_NAME BUILD_LOG=$PUBLIC/$BUILD_LOG_NAME
    rm -rf "$SERVED" "$PUBLIC" "$PUSH_TARGET"
    mkdir -p "$REPO_DIR" "$SERVED/.state" "$PUBLIC_LOGS/sub" "$PUSH_TARGET/$LOGS_NAME" "$PUSH_TARGET/$ARCH"
    echo db > "$REPO_DIR/$REPO.db.tar.gz"
    ln -s "$REPO.db.tar.gz" "$REPO_DIR/$REPO.db"
    echo pkg > "$REPO_DIR/a-1-1.1-x86_64.pkg.tar.zst"
    echo state > "$SERVED/.state/a"
    echo "failed: a: build failed, $LOGS_NAME/a.log" > "$SERVED/status.txt"
    echo '{}' > "$SERVED/status.json"
    echo run > "$BUILD_LOG"
    echo a > "$PUBLIC_LOGS/a.log"
    echo snapshot > "$PUBLIC_LOGS/snapshot.log"
    echo notes > "$PUBLIC_LOGS/notes.txt"
    echo nested > "$PUBLIC_LOGS/sub/c.log"
    ln -s ../../run/signing.asc "$PUBLIC_LOGS/key.log"
    mkfifo "$PUBLIC_LOGS/fifo.log"
    head -c 2048 /dev/zero > "$PUBLIC_LOGS/huge.log"
    echo stale > "$PUSH_TARGET/$LOGS_NAME/gone.log"
    echo stale > "$PUSH_TARGET/$ARCH/gone-1-1.1-x86_64.pkg.tar.zst"
  }
  # <case> <paths the mirror must have> <paths it must not have>
  check_push() {
    local path
    push > push.out 2>&1 || fail "$1: the push failed: $(cat push.out)"
    (( ! push_failed )) || fail "$1: push_failed set"
    for path in $2; do [ -e "$PUSH_TARGET/$path" ] || fail "$1: the mirror lacks $path"; done
    for path in $3; do [ ! -e "$PUSH_TARGET/$path" ] && [ ! -L "$PUSH_TARGET/$path" ] || fail "$1: the mirror has $path"; done
    if grep -rqF "$secret" "$PUSH_TARGET"; then fail "$1: the signing key reached the mirror"; fi
    pass "$1"
  }
  served="status.txt status.json $ARCH/$REPO.db $ARCH/$REPO.db.tar.gz $ARCH/a-1-1.1-x86_64.pkg.tar.zst"
  planted="$LOGS_NAME/notes.txt $LOGS_NAME/sub $LOGS_NAME/key.log $LOGS_NAME/fifo.log $LOGS_NAME/huge.log"
  stale="$LOGS_NAME/gone.log $ARCH/gone-1-1.1-x86_64.pkg.tar.zst .state"

  fixture public
  check_push "the repo, the status and the logs it names arrive; links, fifos, dirs, other files, oversized logs and stale files do not" \
    "$served $BUILD_LOG_NAME $LOGS_NAME/a.log $LOGS_NAME/snapshot.log" "$planted $stale"
  [ "$(cat "$PUSH_TARGET/$LOGS_NAME/a.log")" = a ] || fail "a.log arrived with other contents"

  fixture public-link
  rm "$BUILD_LOG"
  ln -s ../run/signing.asc "$BUILD_LOG"
  check_push "a build.log that is a link stays behind" "$served $LOGS_NAME/a.log" "$BUILD_LOG_NAME"

  fixture public-logs-link
  mkdir -p keys
  ln -s ../run/signing.asc keys/signing.log
  rm -rf "$PUBLIC_LOGS"
  ln -s ../keys "$PUBLIC_LOGS"
  check_push "a logs/ that is a link pushes no log, the rest still goes" "$served $BUILD_LOG_NAME" "$LOGS_NAME/signing.log"
  touch $out
''
