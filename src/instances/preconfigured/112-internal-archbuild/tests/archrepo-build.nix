# single steps of vm-112's nightly build (lib/archrepo-build.sh), sourced in the sandbox.
#
# Build dependencies as a table: what build_deps_wanted installs for a recipe's .SRCINFO. A split base's packages
# depending on their siblings (apparmor.d, opentelemetry-python-contrib) must not ask the repos for them, by name or
# by provides, versioned or not; every other depends and makedepends stays, a name that only shares a prefix with a
# sibling included.
#
# The push to the mirror into a local directory: the served tree (the internet's as hardlinks of the pool), the status
# and the logs status.txt names arrive,
# the final --delete keeps the logs and drops stale repo files, a stale log goes. What the build container could
# plant in the logs never leaves: a link (to the signing key here), a fifo, a directory, a file that is no .log, one
# above the size cap, a build.log that is a link, a logs/ that is a link.
#
# Outages against a stand-in aur (the 2026-10-07 night: 502s from rpc and git): a blip is retried, an outage ends
# the night with EX_TEMPFAIL before any package failure is recorded, an rpc failure of the build's own stays one;
# a name the aur dropped keeps its served base's last build. The staged db's files: each link of the builder's pool
# leads to the outbox or the served pool, a name neither holds stops the run. archrepo-skip.sh records a skipped
# night in the served status and leaves the snapshot and the stale clock alone.
#
# A local recipe over an official package of its name (quickshell, 2026-10-12): the staged db and the final db
# serve the local build whether its version is newer or older than the official one, against real pacman dbs.
#
# The internet's tree beside the full one, published with a real repo key: its db and files db name the own builds
# alone (a local recipe's over an official name included), signed, its files hardlinks of the pool's; it switches and
# prunes like the full one. A prefix that is none, or that would make it the full tree, stops the publish.
#
# The night's budget: a recipe starts only while its whole bound still ends within the budget. A keyserver outage
# defers only the recipes with validpgpkeys.
{ pkgs, lib, ... }:
let
  build = ../lib/archrepo-build.sh;
  port = 18081;
  base = "http://127.0.0.1:${toString port}";
  upstream = (import ../../../../modules/upstream/default.nix {
    inherit lib pkgs;
    lab.upstreams = { aur.url = "${base}/probe"; keyserver.url = "${base}/probe"; };
  })._module.args.upstream;
  # a keyserver that never has the key: what is left to classify is whether the keyserver was up
  gpgStandIn = pkgs.writeShellScriptBin "gpg" "exit 2";
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
    pkgs.git pkgs.python3 pkgs.pacman pkgs.libarchive pkgs.zstd pkgs.gnupg ];
} ''
  set -euo pipefail
  # a run that started now with an hour of recipes: the budget cases below move the clock against it
  budget_s=3600
  export ARCHBUILD_COMMIT=test ARCHBUILD_RUN_STARTED=$(date +%s) ARCHBUILD_BUILD_BUDGET_S=$budget_s
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
    SERVED=$PWD/served REPO_DIR=$PWD/served/$ARCH PUBLIC=$PWD/$1 PUSH_TARGET=$PWD/mirror INTERNET_PREFIX=/public
    PUBLIC_LOGS=$PUBLIC/$LOGS_NAME BUILD_LOG=$PUBLIC/$BUILD_LOG_NAME
    rm -rf "$SERVED" "$PUBLIC" "$PUSH_TARGET"
    mkdir -p "$REPO_DIR" "$SERVED/.state" "$PUBLIC_LOGS/sub" "$PUSH_TARGET/$LOGS_NAME" "$PUSH_TARGET/$ARCH"
    echo db > "$REPO_DIR/$REPO.db.tar.gz"
    ln -s "$REPO.db.tar.gz" "$REPO_DIR/$REPO.db"
    echo pkg > "$REPO_DIR/a-1-1.1-x86_64.pkg.tar.zst"
    # the internet's tree: its db, current and a hardlink of the pool's file
    mkdir -p "$SERVED$INTERNET_PREFIX/$ARCH" "$SERVED$INTERNET_PREFIX/$SNAPSHOT"
    echo internet-db > "$SERVED$INTERNET_PREFIX/$ARCH/$REPO.db.tar.gz"
    ln "$REPO_DIR/a-1-1.1-x86_64.pkg.tar.zst" "$SERVED$INTERNET_PREFIX/$ARCH/"
    ln -s "$SNAPSHOT" "$SERVED$INTERNET_PREFIX/$CURRENT_NAME"
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
  served="status.txt status.json $ARCH/$REPO.db $ARCH/$REPO.db.tar.gz $ARCH/a-1-1.1-x86_64.pkg.tar.zst
    public/$CURRENT_NAME public/$ARCH/$REPO.db.tar.gz public/$ARCH/a-1-1.1-x86_64.pkg.tar.zst"
  planted="$LOGS_NAME/notes.txt $LOGS_NAME/sub $LOGS_NAME/key.log $LOGS_NAME/fifo.log $LOGS_NAME/huge.log"
  stale="$LOGS_NAME/gone.log $ARCH/gone-1-1.1-x86_64.pkg.tar.zst .state"

  fixture public
  check_push "the repo, the status and the logs it names arrive; links, fifos, dirs, other files, oversized logs and stale files do not" \
    "$served $BUILD_LOG_NAME $LOGS_NAME/a.log $LOGS_NAME/snapshot.log" "$planted $stale"
  [ "$(cat "$PUSH_TARGET/$LOGS_NAME/a.log")" = a ] || flunk "a.log arrived with other contents"
  [ "$(stat -c %i "$PUSH_TARGET/public/$ARCH/a-1-1.1-x86_64.pkg.tar.zst")" = "$(stat -c %i "$PUSH_TARGET/$ARCH/a-1-1.1-x86_64.pkg.tar.zst")" ] \
    || flunk "the internet's tree arrived as copies, not hardlinks of the pool"
  pass "the internet's tree arrives as hardlinks of the pool"

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

  # ---- the night's budget ----
  [ "$UNAVAILABLE" = ${toString upstream.unavailable} ] || flunk "UNAVAILABLE $UNAVAILABLE is not modules/upstream's ${toString upstream.unavailable}"
  # <case> <seconds the run has taken> <recipe bound in seconds> <starts: yes|no>
  check_budget() {
    local starts=no
    if (BUILD_DEADLINE=$(( $(date +%s) - $2 + budget_s )) RECIPE_BOUND_S=$3; recipe_time_left); then starts=yes; fi
    [ "$starts" = "$4" ] || flunk "$1: starts $starts, want $4"
    pass "$1"
  }
  check_budget "a recipe that ends well within the budget starts" 0 600 yes
  check_budget "a recipe that ends past the budget waits for the next night" 3000 1200 no
  check_budget "the full bound of the real recipe never fits an hour" 0 "$RECIPE_BOUND_S" no
  check_budget "a run past its budget starts nothing" 7200 1 no

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

  # <case> <keyserver mode> <validpgpkeys> <exit> <failed>
  check_keys() {
    local status=0 result
    echo "$2" > aur/mode
    echo 0 > aur/fails
    mkdir -p keyed
    printf 'pkgbase = keyed\n%s' "$3" > keyed/.SRCINFO
    result=$(failed=(); AS_BUILDER=(env PATH=${gpgStandIn}/bin:$PATH); keys_fetch keyed keyed keys.log > keys.out 2>&1 || status=$?;
      echo "$status ''${!failed[*]}")
    [ "$result" = "$4 $5" ] || flunk "$1: '$result', want '$4 $5': $(cat keys.out keys.log)"
    pass "$1"
  }
  check_keys "a recipe without keys needs no keyserver" down "" 0 ""
  check_keys "a key the keyserver lacks is makepkg's failure, not a deferral" up "validpgpkeys = ABCD" 0 ""
  check_keys "a keyserver outage defers the recipe, the night goes on" down "validpgpkeys = ABCD" 1 keyed

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

  # ---- a local recipe over an official package ----
  # <dir> <name> <version>: a package of only a .PKGINFO, its path printed
  package_make() {
    local tree=$PWD/package-tree file=$1/$2-$3-any.pkg.tar.zst
    rm -rf "$tree"
    mkdir -p "$tree"
    printf 'pkgname = %s\npkgbase = %s\npkgver = %s\narch = any\nsize = 0\n' "$2" "$2" "$3" > "$tree/.PKGINFO"
    bsdtar -C "$tree" -cf - .PKGINFO | zstd -q -c > "$file"
    echo "$file"
  }
  # <case> <official version> <local version>: the official repos have the name at one version, the local recipe
  # built it at another; the staged db and the final db serve the local build, whichever version is newer
  local_over_official_name=quickshell
  check_local_over_official() {
    local name=$local_over_official_name result want
    want=$name-$3-any.pkg.tar.zst
    # not root: snapshot_official has a local of that name, which the pacman stand-in would see
    result=$(
      fixture=$PWD/local-over-official
      rm -rf "$fixture"
      CACHE=$fixture/cache PACMAN_SYNC=$fixture/sync OUTBOX_POOL=$fixture/outbox/pool OUTBOX_SYNC=$fixture/outbox/sync
      OUTBOX_STATE=$fixture/outbox/state REPO_DIR=$fixture/served STAGE_LINKS=$fixture/stage-links STATE_DIR=$fixture/state
      PUBLIC_LOGS=$fixture/logs WORK=$fixture/work STAGE_DB=$fixture/cache/db/$REPO.db.tar.gz OUTBOX_DB=$fixture/cache/db/$REPO.db.tar.gz
      mkdir -p "$CACHE"/{pacman,db} "$PACMAN_SYNC" "$OUTBOX_POOL" "$OUTBOX_SYNC" "$REPO_DIR" "$STATE_DIR" "$PUBLIC_LOGS" \
        "$WORK" "$fixture/official" "$fixture/built"
      # the build container's pacman.conf: the official repos first, the staging db last
      for repo in "''${OFFICIAL_REPOS[@]}"; do
        printf '[%s]\nServer = file://%s\n' "$repo" "$fixture/official" >> "$fixture/repos.conf"
        bsdtar -czf "$PACMAN_SYNC/$repo.db" --files-from /dev/null
      done
      printf '[options]\nArchitecture = auto\nSigLevel = Never\nCacheDir = %s\n%s\n[%s]\nServer = file://%s\n' \
        "$CACHE/pacman" "$(cat "$fixture/repos.conf")" "$REPO" "$STAGE_LINKS" > "$fixture/pacman.conf"
      # a download needs root, which the sandbox is not: the official file is in the pacman cache already
      pacman() { [[ " $* " == *" -Swdd "* ]] || command pacman --config "$fixture/pacman.conf" "$@"; }
      upstream_call() { shift; "$@"; }
      repo-add -q "$fixture/official/extra.db.tar.gz" "$(package_make "$CACHE/pacman" "$name" "$2")" 2>/dev/null
      cp "$fixture/official/extra.db.tar.gz" "$PACMAN_SYNC/extra.db"
      bsdtar -czf "$STAGE_DB" --files-from /dev/null
      kind=([$name]=local) bases=("$name") official_wanted=() failed=()
      state_set "$name" "$(printf '%064d' 0)" 1 "$name" "$want"
      {
        stage_add "$(package_make "$fixture/built" "$name" "$3")" && snapshot_official \
          && echo "staged ''${db_file[$name]}" || echo "held back: $held_back, $(cat "$PUBLIC_LOGS/snapshot.log")"
        # publish, after base_accept signed the local build
        cp -a "$STATE_DIR" "$OUTBOX_STATE"
        state_file=([$want]=$name) owner_of=([$name]=$name) served=([$name]=$name-0.3.1-1-any.pkg.tar.zst)
        assemble && echo "final ''${final[$name]:-}"
      } > "$fixture/run.log" 2>&1 || true
      grep -E '^(staged|final) ' "$fixture/run.log" | xargs
    ) || flunk "$1: $result"
    [ "$result" = "staged $want final $want" ] \
      || flunk "$1: '$result', want the staged and the final db to serve $want: $(cat local-over-official/run.log)"
    pass "$1"
  }
  check_local_over_official "a local recipe newer than the official package serves its build (quickshell, 2026-10-12)" \
    0.3.2-1 0.3.2-2.9
  check_local_over_official "a local recipe older than the official package still serves its build" 0.3.2-5 0.3.2-2.9

  # ---- the internet's tree ----
  export GNUPGHOME=$PWD/gnupg
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key "archbuild test <test@invalid>" ed25519 sign never 2>/dev/null
  KEY=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  SERVED=$PWD/trees REPO_DIR=$PWD/trees/$ARCH WORK=$PWD/trees-work INTERNET_PREFIX=/public
  INTERNET_SERVED=$SERVED$INTERNET_PREFIX
  internet_dir=$INTERNET_SERVED/$ARCH
  mkdir -p "$REPO_DIR" "$WORK/db" "$internet_dir"
  # an aur build, a local recipe's over an official name (quickshell) and an official package; final names all three
  own_aur=tool-1-1.2-any.pkg.tar.zst own_local=quickshell-0.3.2-2.9-any.pkg.tar.zst official_file=glibc-2.40-1-any.pkg.tar.zst
  for file in $own_aur $own_local $official_file; do
    name=$(file_package_name "$file")
    version=''${file#"$name"-}
    package_make "$REPO_DIR" "$name" "''${version%-any.pkg.tar.zst}" > /dev/null
    sign "$REPO_DIR/$file"
  done
  repo-add -q "$WORK/db/$REPO.db.tar.gz" "$REPO_DIR"/*.pkg.tar.zst 2>/dev/null
  final=([tool]=$own_aur [quickshell]=$own_local [glibc]=$official_file)
  state_file=([$own_aur]=tool [$own_local]=quickshell)
  # yesterday's build of tool in the internet's tree, and a snapshot past the kept days
  stale_own=tool-1-1.1-any.pkg.tar.zst
  touch "$internet_dir/$stale_own" "$internet_dir/$stale_own.sig"
  mkdir -p "$INTERNET_SERVED/2000-01-01/$ARCH"
  {
    internet_assemble
    db_publish
    files_prune "$REPO_DIR" "''${final[@]}"
    files_prune "$internet_dir" "''${internet_files[@]}"
    snapshot_prune "$SERVED"
    snapshot_prune "$INTERNET_SERVED"
  } > trees.log 2>&1 || flunk "publishing the trees: $(cat trees.log)"
  # <case> <db> <names, sorted>
  check_db_names() {
    load_db_index "$2" || flunk "$1: $2 cannot be read"
    [ "$(printf '%s\n' "''${!db_file[@]}" | sort | xargs)" = "$3" ] || flunk "$1: names '$(printf '%s\n' "''${!db_file[@]}" | sort | xargs)', want '$3'"
    pass "$1"
  }
  for tree in "$internet_dir" "$INTERNET_SERVED/$SNAPSHOT/$ARCH"; do
    check_db_names "the internet's db names the own builds alone, a local recipe's over an official name included ($tree)" \
      "$tree/$REPO.db" "quickshell tool"
    check_db_names "the internet's files db names the same ($tree)" "$tree/$REPO.files" "quickshell tool"
  done
  check_db_names "the house's db keeps the official packages" "$REPO_DIR/$REPO.db" "glibc quickshell tool"
  for path in "$internet_dir/$REPO.db" "$internet_dir/$REPO.files" "$INTERNET_SERVED/$SNAPSHOT/$SNAPSHOT_MANIFEST"; do
    gpg --batch --verify "$path.sig" "$path" 2>/dev/null || flunk "$path carries no valid signature of the repo key"
  done
  jq -e '.packages == 2' "$INTERNET_SERVED/$SNAPSHOT/$SNAPSHOT_MANIFEST" > /dev/null || flunk "the internet's manifest counts other packages"
  pass "the internet's db, files db and manifest are signed by the repo key"
  for tree in "$internet_dir" "$INTERNET_SERVED/$SNAPSHOT/$ARCH"; do
    for file in $own_aur $own_aur.sig $own_local $own_local.sig; do
      [ "$(stat -c %i "$tree/$file")" = "$(stat -c %i "$REPO_DIR/$file")" ] || flunk "$tree/$file is no hardlink of the pool's"
    done
    [ ! -e "$tree/$official_file" ] && [ ! -e "$tree/$official_file.sig" ] || flunk "$tree serves the official $official_file"
  done
  pass "the internet's trees hardlink the pool's own builds and their signatures, never an official package"
  [ "$(readlink "$INTERNET_SERVED/$CURRENT_NAME")" = "$SNAPSHOT" ] || flunk "the internet's current is not $SNAPSHOT"
  [ ! -e "$internet_dir/$stale_own" ] && [ ! -e "$internet_dir/$stale_own.sig" ] || flunk "a superseded build stayed in the internet's tree"
  [ ! -e "$INTERNET_SERVED/2000-01-01" ] || flunk "a snapshot past the kept days stayed in the internet's tree"
  [ -f "$REPO_DIR/$official_file" ] || flunk "the internet's prune took the pool's official package"
  pass "the internet's tree switches and prunes like the full one, the pool keeps every file"

  # <case> <prefix>: the publish stops before it reads or writes anything
  check_prefix_refused() {
    if (INTERNET_PREFIX=$2; publish_main) > prefix.log 2>&1; then flunk "$1: published"; fi
    grep -q "is no path prefix" prefix.log || flunk "$1: $(cat prefix.log)"
    pass "$1"
  }
  check_prefix_refused "no prefix would make the internet's tree the full one" ""
  check_prefix_refused "a bare slash is no prefix" /
  check_prefix_refused "a prefix that climbs is refused" /..
  check_prefix_refused "a relative prefix is refused" public

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
