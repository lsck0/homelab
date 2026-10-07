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
#
# Outages against a stand-in aur (the 2026-10-07 night: 502s from rpc and git): a blip is retried, an outage ends
# the night with EX_TEMPFAIL before any package failure is recorded, an rpc failure of the build's own stays one;
# a name the aur dropped keeps its served base's last build. The staged db's files: each link of the builder's pool
# leads to the outbox or the served pool, a name neither holds stops the run. archrepo-skip.sh records a skipped
# night in the served status and leaves the snapshot and the stale clock alone.
{ pkgs, lib, ... }:
let
  build = ../lib/archrepo-build.sh;
  port = 18081;
  base = "http://127.0.0.1:${toString port}";
  upstream = (import ../../../modules/upstream/default.nix {
    inherit lib pkgs;
    lab.upstreams.aur.url = "${base}/probe";
  })._module.args.upstream;
  # <state dir>: answers by <state dir>/mode (up, down, rpc-broken), the rpc fails <state dir>/fails times first
  standIn = pkgs.writeText "aur-stand-in.py" ''
    import http.server, json, pathlib, sys, urllib.parse
    state = pathlib.Path(sys.argv[1])
    class Handler(http.server.BaseHTTPRequestHandler):
        def answer(self, query):
            mode = (state / "mode").read_text().strip()
            fails = int((state / "fails").read_text())
            url = urllib.parse.urlparse(self.path)
            body = b""
            if url.path == "/probe":
                code = 502 if mode == "down" else 200
            elif mode == "down" or fails > 0:
                (state / "fails").write_text(str(max(fails - 1, 0)))
                code = 502
            elif mode == "rpc-broken":
                code = 404
            else:
                names = urllib.parse.parse_qs(query).get("arg[]", [])
                code = 200
                body = json.dumps({"results": [{"Name": n, "PackageBase": n} for n in names if not n.startswith("deleted")]}).encode()
            self.send_response(code)
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            self.answer(urllib.parse.urlparse(self.path).query)
        def do_POST(self):
            self.answer(self.rfile.read(int(self.headers["Content-Length"])).decode())
        def log_message(self, *args):
            pass
    http.server.HTTPServer(("127.0.0.1", ${toString port}), Handler).serve_forever()
  '';
in
pkgs.runCommand "archrepo-build" {
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.gnugrep pkgs.findutils pkgs.rsync pkgs.jq pkgs.curl
    pkgs.git pkgs.python3 ];
} ''
  set -euo pipefail
  export ARCHBUILD_COMMIT=test ARCHBUILD_RUN_STARTED=0
  # shellcheck source=/dev/null
  source ${build}
  # the script brings a fail of its own, which the build steps below record failures with
  flunk() { echo "FAIL: $*" >&2; exit 1; }
  pass() { echo "PASS: $*"; }

  # ---- build dependencies ----
  # <case> <.SRCINFO lines, | separated> <wanted deps, space separated, sorted>
  check_deps() {
    local dir=$PWD/recipe
    rm -rf "$dir"
    mkdir -p "$dir"
    tr '|' '\n' <<<"$2" > "$dir/.SRCINFO"
    [ "$(build_deps_wanted "$dir" | xargs)" = "$3" ] || flunk "$1: wanted '$(build_deps_wanted "$dir" | xargs)', want '$3'"
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

  # ---- the completeness gate ----
  # <case> <what current links to> <days since $gate_served at the run> <lost names> <held back: yes|no>
  gate_served=2026-10-05
  check_gate() {
    SNAPSHOT_CURRENT=$PWD/served-gate/current
    rm -rf served-gate
    mkdir -p served-gate
    ln -s "$2" "$SNAPSHOT_CURRENT"
    RUN_STARTED=$(( $(date -u -d "$gate_served" +%s) + $3 * SECONDS_PER_DAY ))
    snapshot_missing=kept
    gate_lost=$4
    # shellcheck disable=SC2086 # one name per word
    listed_missing() { printf '%s\n' kept $gate_lost | LC_ALL=C sort; }
    held_back=
    completeness_check > gate.out
    case "$5" in
      yes) [ -n "$held_back" ] || flunk "$1: published" ;;
      no) [ -z "$held_back" ] || flunk "$1: held back: $held_back" ;;
    esac
    pass "$1"
  }
  check_gate "nothing lost publishes" "$gate_served" 0 "" no
  check_gate "a lost name holds the night back" "$gate_served" 1 "gone" yes
  check_gate "the last night of the hold still holds" "$gate_served" $((COMPLETENESS_HOLD_DAYS - 1)) "gone" yes
  check_gate "past the hold the official updates publish" "$gate_served" "$COMPLETENESS_HOLD_DAYS" "gone other" no
  check_gate "an unreadable snapshot date holds" not-a-date 30 "gone" yes
  check_gate "a link that is no snapshot date holds" ../../etc 30 "gone" yes

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
    push > push.out 2>&1 || flunk "$1: the push failed: $(cat push.out)"
    (( ! push_failed )) || flunk "$1: push_failed set"
    for path in $2; do [ -e "$PUSH_TARGET/$path" ] || flunk "$1: the mirror lacks $path"; done
    for path in $3; do [ ! -e "$PUSH_TARGET/$path" ] && [ ! -L "$PUSH_TARGET/$path" ] || flunk "$1: the mirror has $path"; done
    if grep -rqF "$secret" "$PUSH_TARGET"; then flunk "$1: the signing key reached the mirror"; fi
    pass "$1"
  }
  served="status.txt status.json $ARCH/$REPO.db $ARCH/$REPO.db.tar.gz $ARCH/a-1-1.1-x86_64.pkg.tar.zst"
  planted="$LOGS_NAME/notes.txt $LOGS_NAME/sub $LOGS_NAME/key.log $LOGS_NAME/fifo.log $LOGS_NAME/huge.log"
  stale="$LOGS_NAME/gone.log $ARCH/gone-1-1.1-x86_64.pkg.tar.zst .state"

  fixture public
  check_push "the repo, the status and the logs it names arrive; links, fifos, dirs, other files, oversized logs and stale files do not" \
    "$served $BUILD_LOG_NAME $LOGS_NAME/a.log $LOGS_NAME/snapshot.log" "$planted $stale"
  [ "$(cat "$PUSH_TARGET/$LOGS_NAME/a.log")" = a ] || flunk "a.log arrived with other contents"

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

  # ---- outages of the aur ----
  export HOME=$PWD UPSTREAM_BACKOFF_S=0 UPSTREAM_TIMEOUT_S=5
  UPSTREAM=${upstream.run} AUR_URL=${base} HTTP_BODY=$PWD/aur-answer AUR_FOUND=$PWD/aur-found
  UNAVAILABLE_FILE=$PWD/unavailable STATE_DIR=$PWD/state DOTFILES=$PWD/dotfiles
  mkdir -p aur state
  echo up > aur/mode
  echo 0 > aur/fails
  python3 ${standIn} "$PWD/aur" &
  for _ in $(seq 50); do curl -s -o /dev/null ${base}/probe && break; sleep 0.1; done
  # the served base of a name the aur dropped
  printf 'names=deleted deleted-doc\nfiles=deleted-1-1.1-any.pkg.tar.zst deleted-doc-1-1.1-any.pkg.tar.zst\n' > state/deleted-base

  # <case> <mode> <rpc failures first> <listed names> <exit> <unavailable> <failed, sorted> <resolution complete>
  check_outage() {
    local status=0 result
    echo "$2" > aur/mode
    echo "$3" > aur/fails
    : > "$UNAVAILABLE_FILE"
    result=$(
      kind=() failed=() listed=() provider=() bases=() aur_wanted=() resolve_complete=1
      for name in $4; do listed[$name]=1; aur_wanted+=("$name"); done
      resolve > resolve.log 2>&1
      echo "$(printf '%s\n' "''${!failed[@]}" | sort | xargs) $resolve_complete"
    ) || status=$?
    [ "$status" = "$5" ] || flunk "$1: exit $status, want $5: $(cat resolve.log)"
    [ "$(cat "$UNAVAILABLE_FILE")" = "$6" ] || flunk "$1: unavailable '$(cat "$UNAVAILABLE_FILE")', want '$6'"
    [ "$status" != 0 ] || [ "$result" = "$7 $8" ] || flunk "$1: failed and complete '$result', want '$7 $8'"
    pass "$1"
  }
  check_outage "a dropped name keeps its served base, which fails" up 0 "deleted" 0 "" "deleted-base" 1
  check_outage "a dropped name nothing served fails itself" up 0 "deleted-new" 0 "" "deleted-new" 1
  check_outage "a blip is retried" up 2 "deleted" 0 "" "deleted-base" 1
  check_outage "an outage ends the night before any failure" down 0 "deleted deleted-new" ${toString upstream.unavailable} aur "" ""
  check_outage "failing past the retries while the probe answers is the build's own" up 10 "deleted" 0 "" "" 0
  check_outage "an rpc the aur refuses is the build's own" rpc-broken 0 "deleted" 0 "" "" 0

  # <case> <mode> <exit>: a recipe from the aur's git
  check_recipe() {
    local status=0
    echo "$2" > aur/mode
    echo 0 > aur/fails
    : > "$UNAVAILABLE_FILE"
    (CACHE=$PWD/cache; rm -rf cache recipe; mkdir -p cache/aur recipe; recipe_aur foo "$PWD/recipe") > recipe.log 2>&1 || status=$?
    [ "$status" = "$3" ] || flunk "$1: exit $status, want $3: $(cat recipe.log)"
    pass "$1"
  }
  check_recipe "a git fetch the aur fails while up is the recipe's failure" up 1
  check_recipe "a git fetch during an outage ends the night" down ${toString upstream.unavailable}

  # ---- the builder's pool: the staged db against the files ----
  OUTBOX_POOL=$PWD/outbox-pool REPO_DIR=$PWD/served-pool STAGE_LINKS=$PWD/stage-links
  mkdir -p "$OUTBOX_POOL" "$REPO_DIR"
  touch "$OUTBOX_POOL/new-1-1.2-any.pkg.tar.zst" "$REPO_DIR/python-slowapi-0.1.10-1.1-any.pkg.tar.zst" \
    "$OUTBOX_POOL/both-1-1-any.pkg.tar.zst" "$REPO_DIR/both-1-1-any.pkg.tar.zst"
  db_file=([new]=new-1-1.2-any.pkg.tar.zst [python-slowapi]=python-slowapi-0.1.10-1.1-any.pkg.tar.zst
    [both]=both-1-1-any.pkg.tar.zst)
  stage_links_sync > links.log
  # <case> <file> <pool the link leads to>
  check_link() {
    [ "$(readlink "$STAGE_LINKS/$2")" = "$3/$2" ] || flunk "$1: $2 leads to '$(readlink "$STAGE_LINKS/$2")'"
    pass "$1"
  }
  check_link "a build of this night installs from the outbox" new-1-1.2-any.pkg.tar.zst "$OUTBOX_POOL"
  check_link "a package staged again from an unpublished run installs from the served pool" \
    python-slowapi-0.1.10-1.1-any.pkg.tar.zst "$REPO_DIR"
  check_link "the outbox's copy wins" both-1-1-any.pkg.tar.zst "$OUTBOX_POOL"
  db_file[gone]=gone-1-1-any.pkg.tar.zst
  if (stage_links_sync > links.log); then flunk "a staged name without a file passed"; fi
  grep -q "names gone-1-1-any.pkg.tar.zst for gone" links.log || flunk "no message naming the file: $(cat links.log)"
  pass "a staged name neither pool holds stops the run"

  # ---- a skipped night in the served status ----
  skip() { bash ${../lib/archrepo-skip.sh} skipped "$1" github aur archlinux; }
  mkdir -p skipped
  echo '{"packages":5,"failing":1,"held_back":null,"snapshot":"2026-10-06"}' > skipped/status.json
  printf 'last build: 2026-10-06T03:00:00Z\nsnapshot:   2026-10-06\n' > skipped/status.txt
  touch -d @1000 skipped/status.txt
  skip aur
  jq -e '.unavailable == "aur" and .skipped != null and .packages == 5 and .failing == 1 and .snapshot == "2026-10-06"' \
    skipped/status.json >/dev/null || flunk "the status after a skip: $(cat skipped/status.json)"
  [ "$(stat -c %Y skipped/status.txt)" = 1000 ] || flunk "a skip moved status.txt's clock"
  grep -q '^snapshot:   2026-10-06$' skipped/status.txt || flunk "a skip lost the served snapshot line"
  pass "a skip names the upstream and keeps the snapshot, the counts and the stale clock"
  skip archlinux
  [ "$(grep -c '^skipped:' skipped/status.txt)" = 1 ] && grep -q 'archlinux unavailable' skipped/status.txt \
    || flunk "a second skip: $(cat skipped/status.txt)"
  pass "a second skip replaces the first one's line"
  if skip 'aur"} 1' 2>/dev/null; then flunk "an upstream the build does not call was recorded"; fi
  jq -e '.unavailable == "archlinux"' skipped/status.json >/dev/null || flunk "a refused name changed the status"
  pass "a name that is no upstream of the build is refused"
  rm -rf skipped
  mkdir -p skipped
  skip github
  jq -e '.unavailable == "github"' skipped/status.json >/dev/null && [ -f skipped/status.txt ] || flunk "a first run's skip"
  pass "a first run's skip writes both status files"
  touch $out
''
