# single steps of vm-112's nightly build (lib/archrepo-build.nu) in the sandbox
#
# Build dependencies as a table: a split base's packages depending on their siblings (apparmor.d,
# opentelemetry-python-contrib) must not ask the repos for them, by name or by provides, versioned or not; every other
# depends and makedepends stays, a name that only shares a prefix with a sibling included.
#
# The push to the mirror into a local directory: the served tree (the internet's as hardlinks of the pool), the status
# and the logs status.txt names arrive, the final --delete keeps the logs and drops stale repo files. What the build
# container could plant in the logs never leaves: a link (to the signing key here), a fifo, a directory, a file that is
# no .log, one above the size cap, a build.log that is a link, a logs/ that is a link.
#
# Outages against a stand-in aur: a blip is retried, an outage ends the night with EX_TEMPFAIL before any package
# failure is recorded, an rpc failure of the build's own stays one; a name the aur dropped keeps its served base's last
# build. The staged db's files: each link of the builder's pool leads to the outbox or the served pool, a name neither
# holds stops the run. archrepo-skip.nu records a skipped night and leaves the snapshot and the stale clock alone.
#
# A local recipe over an official package of its name (quickshell): the staged and the final db serve the local build
# whether its version is newer or older than the official one, against real pacman dbs.
#
# The internet's tree beside the full one, published with a real repo key: its db and files db name the own builds
# alone (a local recipe's over an official name included), signed, its files hardlinks of the pool's; it switches and
# prunes like the full one. A prefix that is none, or that would make it the full tree, stops the publish.
#
# The night's budget: a recipe starts only while its whole bound still ends within the budget. A keyserver outage
# defers only the recipes with validpgpkeys.
#
# The parts the port from bash could bend, against what the bash build did: the recipe key hashes byte for byte as
# before (a changed key would rebuild every base the first night); repack's pkgrel 1.<n>, its sibling pins and the
# replaces line; the skip decision (is-current) as a table; publish's acceptance of a rebuilt base as a table; the
# dated snapshots the prune keeps; the db index against a db with a malformed desc.
#
# usage: nu archrepo_build_test.nu <upstream run> <unavailable> <stand-in url> <state dir> <stand-in pacman upstream>,
# beside ../lib; GPG_STAND_IN names a dir with a gpg that always fails

use ../lib/archrepo-build.nu *

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def pass [message: string]: nothing -> nothing {
    print $"PASS: ($message)"
}

def now-s []: nothing -> int {
    (date now | into int) // 1_000_000_000
}

# a step that may end the run (night-skip, die) in a process of its own, with $c and $args; it prints its result as
# one "RESULT <json>" line
def isolated [lib: path, c: record, args: any, code: string]: nothing -> record {
    let program = $"use ($lib | path join archrepo-build.nu | to nuon) *\nlet c = ($c | to nuon)\nlet args = ($args | to nuon)\n($code)"
    let got = do { ^$nu.current-exe --no-config-file -c $program } | complete
    let results = $got.stdout | lines | where { str starts-with "RESULT " }
    let result = if ($results | is-empty) { null } else { $results | last | str substring 7.. | from json }
    {exit_code: $got.exit_code, output: $"($got.stdout)($got.stderr)", result: $result}
}

def write-lines [file: path, lines: list<string>]: nothing -> nothing {
    mkdir ($file | path dirname)
    $lines | str join "\n" | $"($in)\n" | save --force $file
}

# a package of only a .PKGINFO, its path; extra lines go into the .PKGINFO, the file name is taken as given
def package-make [dir: path, name: string, version: string, extra: list<string> = [], file_name?: string]: nothing -> path {
    let tree = $env.PWD | path join package-tree
    rm --recursive --force $tree
    mkdir $tree
    write-lines ($tree | path join .PKGINFO) ([$"pkgname = ($name)" $"pkgbase = ($name)" $"pkgver = ($version)" "arch = any" "size = 0"] | append $extra)
    let file = $dir | path join ($file_name | default $"($name)-($version)-any.pkg.tar.zst")
    ^bsdtar -C $tree -cf - .PKGINFO | ^zstd -q -c | save --force --raw $file
    $file
}

def inode [file: path]: nothing -> string {
    ^stat -c %i $file | str trim
}

def deps-check []: nothing -> nothing {
    let cases = [
        [name srcinfo want];
        ["a single package installs its depends and makedepends"
            "pkgbase = tool|  makedepends = go|  depends = glibc|pkgname = tool" [glibc go]]
        ["a split meta package's siblings are not installed (apparmor.d)"
            "pkgbase = apparmor.d|  makedepends = go|  makedepends = just|  depends = apparmor>=4.1.3|  depends = apparmor<5.0.0|pkgname = apparmor.d|  depends = apparmor|  depends = apparmor.d-base|  depends = apparmor.d-tools|pkgname = apparmor.d-base|pkgname = apparmor.d-tools"
            [apparmor apparmor<5.0.0 apparmor>=4.1.3 go just]]
        ["a versioned sibling depends is not installed"
            "pkgbase = frida|pkgname = frida|pkgname = python-frida|  depends = frida=17.18.0-2|  depends = python" [python]]
        ["a sibling reached through its provides is not installed (opentelemetry-python-contrib)"
            "pkgbase = opentelemetry-python-contrib|  makedepends = python-build|pkgname = python-opentelemetry-instrumentation-openai-v2|  depends = python-opentelemetry-util-genai>=0.1|  depends = python-opentelemetry-api|pkgname = python-otel-util|  provides = python-opentelemetry-util-genai=0.2"
            [python-build python-opentelemetry-api]]
        ["a name that only shares a prefix with a sibling is installed"
            "pkgbase = apparmor.d|pkgname = apparmor.d|  depends = apparmor.d-base-extra|pkgname = apparmor.d-base" [apparmor.d-base-extra]]
        ["a recipe without depends installs nothing" "pkgbase = data|pkgname = data" []]
    ]
    let dir = $env.PWD | path join recipe
    for case in $cases {
        rm --recursive --force $dir
        mkdir $dir
        write-lines ($dir | path join .SRCINFO) ($case.srcinfo | split row "|")
        let got = build-deps-wanted $dir
        if $got != $case.want { fail $"($case.name): wanted ($got), want ($case.want)" }
        pass $case.name
    }
}

def gate-check []: nothing -> nothing {
    let served = "2026-10-05"
    let served_s = ($"($served)T00:00:00Z" | into datetime | into int) // 1_000_000_000
    # <case> <what current links to> <days since the served snapshot at the run> <lost names> <held back>
    let cases = [
        [name link days lost held];
        ["nothing lost publishes" $served 0 [] false]
        ["a lost name holds the night back" $served 1 [gone] true]
        ["the last night of the hold still holds" $served ($COMPLETENESS_HOLD_DAYS - 1) [gone] true]
        ["past the hold the official updates publish" $served $COMPLETENESS_HOLD_DAYS [gone other] false]
        ["an unreadable snapshot date holds" not-a-date 30 [gone] true]
        ["a link that is no snapshot date holds" ../../etc 30 [gone] true]
    ]
    for case in $cases {
        let dir = $env.PWD | path join served-gate
        rm --recursive --force $dir
        mkdir $dir
        ^ln -s $case.link ($dir | path join current)
        let c = context-default | merge {snapshot_current: ($dir | path join current), run_started: ($served_s + $case.days * $SECONDS_PER_DAY)}
        let p = publish-empty | upsert snapshot_missing [kept]
        let p = completeness-check $c $p ([kept] | append $case.lost | sort)
        if ($p.held_back != "") != $case.held { fail $"($case.name): held back '($p.held_back)'" }
        pass $case.name
    }
}

def push-fixture [c: record, secret_file: path]: nothing -> nothing {
    rm --recursive --force $c.served $c.public $c.push_target
    let snapshot = (($c.run_started * 1_000_000_000) | into datetime | date to-timezone UTC | format date "%Y-%m-%d")
    let internet = $"($c.served)($c.internet_prefix)"
    mkdir $c.repo_dir ($c.served | path join .state) ($c.public_logs | path join sub) ($c.push_target | path join $LOGS_NAME) ($c.push_target | path join $ARCH)
    mkdir ($internet | path join $ARCH) ($internet | path join $snapshot)
    "db\n" | save ($c.repo_dir | path join $"($REPO).db.tar.gz")
    ^ln -s $"($REPO).db.tar.gz" ($c.repo_dir | path join $"($REPO).db")
    "pkg\n" | save ($c.repo_dir | path join a-1-1.1-x86_64.pkg.tar.zst)
    "internet-db\n" | save ($internet | path join $ARCH $"($REPO).db.tar.gz")
    ^ln ($c.repo_dir | path join a-1-1.1-x86_64.pkg.tar.zst) ($internet | path join $ARCH)
    ^ln -s $snapshot ($internet | path join $CURRENT_NAME)
    "state\n" | save ($c.served | path join .state a)
    $"failed: a: build failed, ($LOGS_NAME)/a.log\n" | save ($c.served | path join status.txt)
    "{}\n" | save ($c.served | path join status.json)
    "run\n" | save $c.build_log
    "a\n" | save ($c.public_logs | path join a.log)
    "snapshot\n" | save ($c.public_logs | path join snapshot.log)
    "notes\n" | save ($c.public_logs | path join notes.txt)
    "nested\n" | save ($c.public_logs | path join sub c.log)
    ^ln -s $secret_file ($c.public_logs | path join key.log)
    ^mkfifo ($c.public_logs | path join fifo.log)
    "" | fill -c "x" -w 2048 | save ($c.public_logs | path join huge.log)
    "stale\n" | save ($c.push_target | path join $LOGS_NAME gone.log)
    "stale\n" | save ($c.push_target | path join $ARCH gone-1-1.1-x86_64.pkg.tar.zst)
}

def push-check [c: record, name: string, has: list<string>, lacks: list<string>, secret: string]: nothing -> nothing {
    if not (push $c) { fail $"($name): the push failed" }
    for path in $has { if not ($c.push_target | path join $path | path exists) { fail $"($name): the mirror lacks ($path)" } }
    for path in $lacks { if ($c.push_target | path join $path | path type | is-not-empty) { fail $"($name): the mirror has ($path)" } }
    if (do { ^grep -rqF $secret $c.push_target } | complete).exit_code == 0 { fail $"($name): the signing key reached the mirror" }
    pass $name
}

def push-cases []: nothing -> nothing {
    let secret = "SIGNING-KEY-MATERIAL"
    mkdir run
    let secret_file = $env.PWD | path join run signing.asc
    $"($secret)\n" | save --force $secret_file
    touch run/push-key
    let base = context-default | merge {
        served: ($env.PWD | path join served), repo_dir: ($env.PWD | path join served $ARCH), push_target: ($env.PWD | path join mirror)
        internet_prefix: /public, push_key_file: ($env.PWD | path join run push-key), log_push_size_max: 1K, run_started: (now-s)
    }
    let at = {|public| $base | merge {public: $public, public_logs: ($public | path join $LOGS_NAME), build_log: ($public | path join $BUILD_LOG_NAME)} }
    let served = [status.txt status.json $"($ARCH)/($REPO).db" $"($ARCH)/($REPO).db.tar.gz" $"($ARCH)/a-1-1.1-x86_64.pkg.tar.zst"
        $"public/($CURRENT_NAME)" $"public/($ARCH)/($REPO).db.tar.gz" $"public/($ARCH)/a-1-1.1-x86_64.pkg.tar.zst"]
    let planted = [notes.txt sub key.log fifo.log huge.log] | each { $"($LOGS_NAME)/($in)" }
    let stale = [$"($LOGS_NAME)/gone.log" $"($ARCH)/gone-1-1.1-x86_64.pkg.tar.zst" .state]

    let c = do $at ($env.PWD | path join public)
    push-fixture $c $secret_file
    push-check $c "the repo, the status and the logs it names arrive; links, fifos, dirs, other files, oversized logs and stale files do not" ($served | append [$BUILD_LOG_NAME $"($LOGS_NAME)/a.log" $"($LOGS_NAME)/snapshot.log"]) ($planted | append $stale) $secret
    if (open --raw ($c.push_target | path join $LOGS_NAME a.log)) != "a\n" { fail "a.log arrived with other contents" }
    if (inode ($c.push_target | path join public $ARCH a-1-1.1-x86_64.pkg.tar.zst)) != (inode ($c.push_target | path join $ARCH a-1-1.1-x86_64.pkg.tar.zst)) {
        fail "the internet's tree arrived as copies, not hardlinks of the pool"
    }
    pass "the internet's tree arrives as hardlinks of the pool"

    let c = do $at ($env.PWD | path join public-link)
    push-fixture $c $secret_file
    rm $c.build_log
    ^ln -s $secret_file $c.build_log
    push-check $c "a build.log that is a link stays behind" ($served | append $"($LOGS_NAME)/a.log") [$BUILD_LOG_NAME] $secret

    let c = do $at ($env.PWD | path join public-logs-link)
    push-fixture $c $secret_file
    mkdir keys
    ^ln -sf $secret_file keys/signing.log
    rm --recursive $c.public_logs
    ^ln -s ($env.PWD | path join keys) $c.public_logs
    push-check $c "a logs/ that is a link pushes no log, the rest still goes" ($served | append $BUILD_LOG_NAME) [$"($LOGS_NAME)/signing.log"] $secret
}

def budget-check [unavailable: int]: nothing -> nothing {
    if $UNAVAILABLE != $unavailable { fail $"UNAVAILABLE ($UNAVAILABLE) is not modules/upstream's ($unavailable)" }
    let budget_s = 3600
    # <case> <seconds the run has taken> <recipe bound in seconds> <starts>
    let cases = [
        [name taken bound starts];
        ["a recipe that ends well within the budget starts" 0 600 true]
        ["a recipe that ends past the budget waits for the next night" 3000 1200 false]
        ["the full bound of the real recipe never fits an hour" 0 $RECIPE_BOUND_S false]
        ["a run past its budget starts nothing" 7200 1 false]
    ]
    for case in $cases {
        let c = context-default | merge {build_deadline: ((now-s) - $case.taken + $budget_s), recipe_bound_s: $case.bound}
        if (recipe-time-left $c) != $case.starts { fail $"($case.name): starts (not $case.starts)" }
        pass $case.name
    }
}

def outage-cases [lib: path, upstream: path, unavailable: int, aur_url: string, aur_state: path]: nothing -> nothing {
    let c = context-default | merge {
        upstream: $upstream, aur_url: $aur_url, cache: ($env.PWD | path join cache), unavailable_file: ($env.PWD | path join unavailable)
        dotfiles: ($env.PWD | path join dotfiles), as_builder: [env $"PATH=($env.GPG_STAND_IN):($env.PATH | str join ':')"]
    }
    mkdir cache/state cache/aur
    # the served base of a name the aur dropped
    write-lines cache/state/deleted-base ["names=deleted deleted-doc" "files=deleted-1-1.1-any.pkg.tar.zst deleted-doc-1-1.1-any.pkg.tar.zst"]
    let aur = {|mode, fails|
        $mode | save --force ($aur_state | path join mode)
        $fails | into string | save --force ($aur_state | path join fails)
        "" | save --force unavailable
    }

    # <case> <mode> <rpc failures first> <listed names> <exit> <unavailable> <failed, sorted> <resolution complete>
    let cases = [
        [name mode fails listed exit unavailable failed complete];
        ["a dropped name keeps its served base, which fails" up 0 [deleted] 0 "" [deleted-base] true]
        ["a dropped name nothing served fails itself" up 0 [deleted-new] 0 "" [deleted-new] true]
        ["a blip is retried" up 2 [deleted] 0 "" [deleted-base] true]
        ["an outage ends the night before any failure" down 0 [deleted deleted-new] $unavailable aur [] false]
        ["failing past the retries while the probe answers is the build's own" up 10 [deleted] 0 "" [] false]
        ["an rpc the aur refuses is the build's own" rpc-broken 0 [deleted] 0 "" [] false]
    ]
    for case in $cases {
        do $aur $case.mode $case.fails
        let got = isolated $lib $c $case.listed r#'
            let n = resolve $c (night-empty | merge {listed: ($args | to-set), aur_wanted: $args})
            print $"RESULT ({failed: ($n.failed | columns | sort), complete: $n.resolve_complete} | to json --raw)"
        '#
        if $got.exit_code != $case.exit { fail $"($case.name): exit ($got.exit_code), want ($case.exit): ($got.output)" }
        let marked = open --raw unavailable | str trim
        if $marked != $case.unavailable { fail $"($case.name): unavailable '($marked)', want '($case.unavailable)'" }
        if $case.exit == 0 and $got.result != {failed: $case.failed, complete: $case.complete} {
            fail $"($case.name): ($got.result | to nuon), want failed ($case.failed) complete ($case.complete)"
        }
        pass $case.name
    }

    # a recipe from the aur's git: <case> <mode> <exit>
    for case in [[name mode exit]; ["a git fetch the aur fails while up is the recipe's failure" up 1] ["a git fetch during an outage ends the night" down $unavailable]] {
        do $aur $case.mode 0
        rm --recursive --force cache/aur recipe
        mkdir cache/aur recipe
        let got = isolated $lib $c ($env.PWD | path join recipe) r#'if not (recipe-aur $c foo $args) { exit 1 }'#
        if $got.exit_code != $case.exit { fail $"($case.name): exit ($got.exit_code), want ($case.exit): ($got.output)" }
        pass $case.name
    }

    # <case> <keyserver mode> <validpgpkeys> <deferred> <failed>
    let keyed = [
        [name mode keys ok failed];
        ["a recipe without keys needs no keyserver" down "" true []]
        ["a key the keyserver lacks is makepkg's failure, not a deferral" up "validpgpkeys = ABCD" true []]
        ["a keyserver outage defers the recipe, the night goes on" down "validpgpkeys = ABCD" false [keyed]]
    ]
    for case in $keyed {
        do $aur $case.mode 0
        mkdir keyed
        write-lines keyed/.SRCINFO ["pkgbase = keyed" $case.keys]
        let got = isolated $lib $c $env.PWD r#'
            let keys = keys-fetch $c (night-empty) keyed ($args | path join keyed) ($args | path join keys.log)
            print $"RESULT ({ok: $keys.ok, failed: ($keys.n.failed | columns)} | to json --raw)"
        '#
        if $got.result != {ok: $case.ok, failed: $case.failed} { fail $"($case.name): ($got.result | to nuon): ($got.output)" }
        pass $case.name
    }
}

def pool-cases [lib: path]: nothing -> nothing {
    let outbox_pool = $env.PWD | path join outbox-pool
    let repo_dir = $env.PWD | path join served-pool
    let stage_links = $env.PWD | path join stage-links
    mkdir $outbox_pool $repo_dir
    for file in [($outbox_pool | path join new-1-1.2-any.pkg.tar.zst) ($repo_dir | path join python-slowapi-0.1.10-1.1-any.pkg.tar.zst)
        ($outbox_pool | path join both-1-1-any.pkg.tar.zst) ($repo_dir | path join both-1-1-any.pkg.tar.zst)] { touch $file }
    let c = context-default | merge {outbox_pool: $outbox_pool, repo_dir: $repo_dir, stage_links: $stage_links}
    let db_file = {new: new-1-1.2-any.pkg.tar.zst, python-slowapi: python-slowapi-0.1.10-1.1-any.pkg.tar.zst, both: both-1-1-any.pkg.tar.zst}
    stage-links-sync $c $db_file
    for case in [
        [name file pool];
        ["a build of this night installs from the outbox" new-1-1.2-any.pkg.tar.zst $outbox_pool]
        ["a package staged again from an unpublished run installs from the served pool" python-slowapi-0.1.10-1.1-any.pkg.tar.zst $repo_dir]
        ["the outbox's copy wins" both-1-1-any.pkg.tar.zst $outbox_pool]
    ] {
        let target = ^readlink ($stage_links | path join $case.file) | str trim
        if $target != ($case.pool | path join $case.file) { fail $"($case.name): ($case.file) leads to '($target)'" }
        pass $case.name
    }
    let got = isolated $lib $c ($db_file | upsert gone gone-1-1-any.pkg.tar.zst) r#'stage-links-sync $c $args'#
    if $got.exit_code == 0 { fail "a staged name without a file passed" }
    if not ($got.output | str contains "names gone-1-1-any.pkg.tar.zst for gone") { fail $"no message naming the file: ($got.output)" }
    pass "a staged name neither pool holds stops the run"
}

# the official repos have the name at one version, the local recipe built it at another; the staged db and the final
# db serve the local build, whichever version is newer
def local-over-official [pacman_upstream: path, name: string, official: string, local: string]: nothing -> nothing {
    let want = $"quickshell-($local)-any.pkg.tar.zst"
    let fixture = $env.PWD | path join local-over-official
    rm --recursive --force $fixture
    let cache = $fixture | path join cache
    let c = context-default | merge {
        cache: $cache, pacman_sync: ($fixture | path join sync), outbox_pool: ($fixture | path join outbox pool)
        outbox_sync: ($fixture | path join outbox sync), outbox_state: ($fixture | path join outbox state)
        repo_dir: ($fixture | path join served), stage_links: ($fixture | path join stage-links)
        public_logs: ($fixture | path join logs), work: ($fixture | path join work)
        stage_db: ($cache | path join db $"($REPO).db.tar.gz"), outbox_db: ($cache | path join db $"($REPO).db.tar.gz")
        pacman_conf: ($fixture | path join pacman.conf), upstream: $pacman_upstream
    }
    mkdir ($cache | path join pacman) ($cache | path join db) ($cache | path join state) $c.pacman_sync $c.outbox_pool $c.outbox_sync $c.repo_dir $c.public_logs $c.work ($fixture | path join official) ($fixture | path join built)
    # the build container's pacman.conf: the official repos first, the staging db last
    let repos = $OFFICIAL_REPOS | each {|repo|
        ^bsdtar -czf ($c.pacman_sync | path join $"($repo).db") --files-from /dev/null
        $"[($repo)]\nServer = file://($fixture)/official"
    }
    write-lines $c.pacman_conf ([
        "[options]" "Architecture = auto" "SigLevel = Never" $"CacheDir = ($cache)/pacman"
    ] | append $repos | append [$"[($REPO)]" $"Server = file://($c.stage_links)"])
    ^repo-add -q ($fixture | path join official extra.db.tar.gz) (package-make ($cache | path join pacman) quickshell $official) e>| ignore
    ^cp ($fixture | path join official extra.db.tar.gz) ($c.pacman_sync | path join extra.db)
    ^bsdtar -czf $c.stage_db --files-from /dev/null
    state-set ($cache | path join state) quickshell ("" | fill -c "0" -w 64) 1 [quickshell] [$want]
    let n = night-empty | merge {kind: {quickshell: local}, bases: [quickshell]}
    let n = stage-add $c $n [(package-make ($fixture | path join built) quickshell $local)]
    let n = snapshot-official $c $n
    if $n.held_back != "" { fail $"($name): held back: ($n.held_back): (open --raw ($c.public_logs | path join snapshot.log))" }
    if ($n.db_file | get -o quickshell) != $want { fail $"($name): staged ($n.db_file | get -o quickshell), want ($want)" }
    # publish, after base-accept signed the local build
    ^cp -a ($cache | path join state) $c.outbox_state
    let p = publish-empty | merge {
        state_file: ({} | upsert $want quickshell), owner_of: {quickshell: quickshell}, served: {quickshell: quickshell-0.3.1-1-any.pkg.tar.zst}
    }
    let p = assemble $c $p
    if ($p.final | get -o quickshell) != $want { fail $"($name): final ($p.final | get -o quickshell), want ($want)" }
    pass $name
}

def internet-cases [lib: path]: nothing -> nothing {
    $env.GNUPGHOME = $env.PWD | path join gnupg
    mkdir $env.GNUPGHOME
    ^chmod 700 $env.GNUPGHOME
    do { ^gpg --batch --pinentry-mode loopback --passphrase "" --quick-gen-key "archbuild test <test@invalid>" ed25519 sign never } | complete | ignore
    let key = ^gpg --with-colons --list-secret-keys | lines | each { split row ":" } | where { $in.0 == fpr } | get 0.9
    let served = $env.PWD | path join trees
    let c = context-default | merge {
        served: $served, repo_dir: ($served | path join $ARCH), work: ($env.PWD | path join trees-work), internet_prefix: /public
        internet_served: ($served | path join public), key: $key, run_started: (now-s)
    }
    let snapshot = (date now | date to-timezone UTC | format date "%Y-%m-%d")
    let internet_dir = $c.internet_served | path join $ARCH
    mkdir $c.repo_dir ($c.work | path join db) $internet_dir
    # an aur build, a local recipe's over an official name (quickshell) and an official package; final names all three
    let own_aur = "tool-1-1.2-any.pkg.tar.zst"
    let own_local = "quickshell-0.3.2-2.9-any.pkg.tar.zst"
    let official = "glibc-2.40-1-any.pkg.tar.zst"
    for file in [$own_aur $own_local $official] {
        let name = file-package-name $file
        let version = $file | str substring (($name | str length) + 1).. | str replace "-any.pkg.tar.zst" ""
        sign $c (package-make $c.repo_dir $name $version)
    }
    let p = publish-empty | merge {
        final: {tool: $own_aur, quickshell: $own_local, glibc: $official}
        state_file: ({} | upsert $own_aur tool | upsert $own_local quickshell)
    }
    # a first run: the served db is empty, every final name is added
    let p = db-assemble $c $p
    if $p.held_back != "" { fail $"assembling the db held back: ($p.held_back)" }
    # yesterday's build of tool in the internet's tree, and a snapshot past the kept days
    let stale_own = "tool-1-1.1-any.pkg.tar.zst"
    touch ($internet_dir | path join $stale_own) ($internet_dir | path join $"($stale_own).sig")
    mkdir ($c.internet_served | path join 2000-01-01 $ARCH)
    let p = internet-assemble $c $p
    db-publish $c $p
    files-prune $c.repo_dir ($p.final | values)
    files-prune $internet_dir $p.internet_files
    snapshot-prune $c $c.served
    snapshot-prune $c $c.internet_served

    let names = {|db| db-index $db | columns | sort }
    for tree in [$internet_dir ($c.internet_served | path join $snapshot $ARCH)] {
        for db in [$"($REPO).db" $"($REPO).files"] {
            let got = do $names ($tree | path join $db)
            if $got != [quickshell tool] { fail $"the internet's ($db) in ($tree) names ($got)" }
        }
    }
    pass "the internet's db and files db name the own builds alone, a local recipe's over an official name included"
    if (do $names ($c.repo_dir | path join $"($REPO).db")) != [glibc quickshell tool] { fail "the house's db lost the official packages" }
    pass "the house's db keeps the official packages"
    for path in [($internet_dir | path join $"($REPO).db") ($internet_dir | path join $"($REPO).files") ($c.internet_served | path join $snapshot $SNAPSHOT_MANIFEST)] {
        if (do { ^gpg --batch --verify $"($path).sig" $path } | complete).exit_code != 0 { fail $"($path) carries no valid signature of the repo key" }
    }
    if (open --raw ($c.internet_served | path join $snapshot $SNAPSHOT_MANIFEST) | from json | get packages) != 2 { fail "the internet's manifest counts other packages" }
    pass "the internet's db, files db and manifest are signed by the repo key"
    for tree in [$internet_dir ($c.internet_served | path join $snapshot $ARCH)] {
        for file in [$own_aur $"($own_aur).sig" $own_local $"($own_local).sig"] {
            if (inode ($tree | path join $file)) != (inode ($c.repo_dir | path join $file)) { fail $"($tree)/($file) is no hardlink of the pool's" }
        }
        if ($tree | path join $official | path exists) or ($tree | path join $"($official).sig" | path exists) { fail $"($tree) serves the official ($official)" }
    }
    pass "the internet's trees hardlink the pool's own builds and their signatures, never an official package"
    if (^readlink ($c.internet_served | path join $CURRENT_NAME) | str trim) != $snapshot { fail $"the internet's current is not ($snapshot)" }
    if ($internet_dir | path join $stale_own | path exists) or ($internet_dir | path join $"($stale_own).sig" | path exists) { fail "a superseded build stayed in the internet's tree" }
    if ($c.internet_served | path join 2000-01-01 | path exists) { fail "a snapshot past the kept days stayed in the internet's tree" }
    if not ($c.repo_dir | path join $official | path exists) { fail "the internet's prune took the pool's official package" }
    pass "the internet's tree switches and prunes like the full one, the pool keeps every file"

    let bogus = "bogus-1-1-any.pkg.tar.zst"
    package-make $c.repo_dir bogus 1-1 | ignore
    "not a signature" | save --force ($c.repo_dir | path join $"($bogus).sig")
    let p = db-assemble ($c | merge {work: ($env.PWD | path join bogus-work)}) ($p | upsert final ($p.final | upsert bogus $bogus))
    if $p.held_back != $"($bogus) has no valid signature" { fail $"a file without a valid signature: held back '($p.held_back)'" }
    pass "a file without a valid signature of the repo key holds the night back"

    # the publish stops before it reads or writes anything
    for case in [[name prefix]; ["no prefix would make the internet's tree the full one" ""] ["a bare slash is no prefix" /] ["a prefix that climbs is refused" /..] ["a relative prefix is refused" public]] {
        let got = with-env {ARCHBUILD_INTERNET_PREFIX: $case.prefix, ARCHBUILD_COMMIT: test, ARCHBUILD_RUN_STARTED: (now-s | into string), ARCHBUILD_BUILD_BUDGET_S: "0"} {
            do { ^$nu.current-exe --no-config-file ($lib | path join archrepo-build.nu) publish } | complete
        }
        if $got.exit_code == 0 { fail $"($case.name): published" }
        if not ($got.stdout | str contains "is no path prefix") { fail $"($case.name): ($got.stdout)($got.stderr)" }
        pass $case.name
    }
}

def skip-cases [lib: path]: nothing -> nothing {
    let skip = {|upstream| do { ^$nu.current-exe --no-config-file ($lib | path join archrepo-skip.nu) skipped $upstream github aur archlinux } | complete }
    mkdir skipped
    '{"packages":5,"failing":1,"held_back":null,"snapshot":"2026-10-06"}' | save --force skipped/status.json
    "last build: 2026-10-06T03:00:00Z\nsnapshot:   2026-10-06\n" | save --force skipped/status.txt
    ^touch -d @1000 skipped/status.txt
    do $skip aur | ignore
    let status = open --raw skipped/status.json | from json
    if not ($status.unavailable == aur and $status.skipped != null and $status.packages == 5 and $status.failing == 1 and $status.snapshot == "2026-10-06") {
        fail $"the status after a skip: ($status | to nuon)"
    }
    if (^stat -c %Y skipped/status.txt | str trim) != "1000" { fail "a skip moved status.txt's clock" }
    if not (open --raw skipped/status.txt | lines | any { $in == "snapshot:   2026-10-06" }) { fail "a skip lost the served snapshot line" }
    pass "a skip names the upstream and keeps the snapshot, the counts and the stale clock"
    do $skip archlinux | ignore
    let text = open --raw skipped/status.txt
    if ($text | lines | where { str starts-with "skipped:" } | length) != 1 or not ($text | str contains "archlinux unavailable") {
        fail $"a second skip: ($text)"
    }
    pass "a second skip replaces the first one's line"
    if (do $skip 'aur"} 1').exit_code == 0 { fail "an upstream the build does not call was recorded" }
    if (open --raw skipped/status.json | from json | get unavailable) != archlinux { fail "a refused name changed the status" }
    pass "a name that is no upstream of the build is refused"
    rm --recursive skipped
    mkdir skipped
    do $skip github | ignore
    if (open --raw skipped/status.json | from json | get unavailable) != github or not ("skipped/status.txt" | path exists) { fail "a first run's skip" }
    pass "a first run's skip writes both status files"
}

# the recipe key as the bash builder computed it, the oracle the port must match byte for byte
const BASH_RECIPE_KEY = '{ echo "repack $1"; cd "$2" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum; } | sha256sum | cut -d" " -f1'

def recipe-key-cases []: nothing -> nothing {
    let dir = $env.PWD | path join keyed-recipe
    rm --recursive --force $dir
    mkdir ($dir | path join sub)
    # C order puts B before a and .SRCINFO first; a space and a backslash are what sha256sum escapes
    for file in [PKGBUILD .SRCINFO B a "with space" 'back\slash' sub/z] { $"($file)\n" | save --force ($dir | path join $file) }
    let want = ^bash -c $BASH_RECIPE_KEY bash ($REPACK_VERSION | into string) $dir | str trim
    let got = recipe-key $dir
    if $got != $want { fail $"the recipe key is ($got), the bash builder's ($want)" }
    pass "the recipe key hashes as the bash builder's did, so the first nu night rebuilds nothing"
}

# <case> <pkgver> <build> <.PKGINFO lines> <file name> <.PKGINFO lines after>
def repack-cases []: nothing -> nothing {
    let c = context-default | merge {cache: ($env.PWD | path join repack-cache)}
    mkdir $c.cache
    let cases = [
        [name pkgver build extra file want];
        ["release 1 becomes 1.<build>" 1.0-1 3 [] tool-1.0-1.3-any.pkg.tar.zst [] ]
        ["a dotted aur release keeps its integer part" 1.0-2.1 5 [] tool-1.0-2.5-any.pkg.tar.zst [] ]
        ["an epoch stays in the version" 1:2.0-1 2 [] tool-1:2.0-1.2-any.pkg.tar.zst [] ]
        ["a pin on a sibling follows the new release (python-frida)" 17.18.0-2 4
            ["depend = frida=17.18.0-2" "depend = python>=3.12" "optdepend = frida=17.18.0-2: the cli" "provides = tool-api=17.18.0-2" "conflicts = tool-old<17.18.0-2"]
            tool-17.18.0-2.4-any.pkg.tar.zst
            ["depend = frida=17.18.0-2.4" "depend = python>=3.12" "optdepend = frida=17.18.0-2.4: the cli" "provides = tool-api=17.18.0-2.4" "conflicts = tool-old<17.18.0-2.4"]]
        ["a pin on another version, or one that only starts like it, stays" 1.0-1 2
            ["depend = other=1.0-10" "depend = lib=0.1.0-1" "depend = near=1x0-1"] tool-1.0-1.2-any.pkg.tar.zst
            ["depend = other=1.0-10" "depend = lib=0.1.0-1" "depend = near=1x0-1"]]
    ]
    for case in $cases {
        let built = $env.PWD | path join repack-built
        rm --recursive --force $built
        mkdir $built
        let tree = $env.PWD | path join repack-tree
        rm --recursive --force $tree
        mkdir ($tree | path join usr bin)
        write-lines ($tree | path join .PKGINFO) (["pkgname = tool" "pkgbase = tool" $"pkgver = ($case.pkgver)" "arch = any" "size = 0"] | append $case.extra)
        write-lines ($tree | path join .BUILDINFO) ["format = 2" "pkgname = tool" "pkgbase = tool" $"pkgver = ($case.pkgver)"]
        write-lines ($tree | path join usr bin tool) ["#!/bin/sh"]
        let package = $built | path join tool-input.pkg.tar.zst
        do { cd $tree; ^bsdtar -cf - .PKGINFO .BUILDINFO usr | ^zstd -q -c | save --force --raw $package }
        let out = repack $c $package $case.build
        if ($out | path basename) != $case.file { fail $"($case.name): ($out | path basename), want ($case.file)" }
        let new = $case.file | str replace --regex '^tool-(.*)-any\.pkg\.tar\.zst$' '$1'
        let pkginfo = ^bsdtar -xOf $out .PKGINFO | lines
        let want = ["pkgname = tool" "pkgbase = tool" $"pkgver = ($new)" "arch = any" "size = 0"] | append $case.want | append "replaces = lsck0-tool"
        if $pkginfo != $want { fail $"($case.name): .PKGINFO ($pkginfo | to nuon), want ($want | to nuon)" }
        if not (^bsdtar -xOf $out .BUILDINFO | lines | any { $in == $"pkgver = ($new)" }) { fail $"($case.name): .BUILDINFO keeps the old pkgver" }
        let listed = ^bsdtar -tf $out | lines
        if $listed != [.BUILDINFO .MTREE .PKGINFO usr/ usr/bin/ usr/bin/tool] { fail $"($case.name): the archive holds ($listed | to nuon)" }
        if not (^bsdtar -xOf $out .MTREE | ^gzip -dc | str contains "./usr/bin/tool") { fail $"($case.name): the .MTREE lacks the files" }
        pass $case.name
    }
}

# the skip decision: a base whose recipe and staged build are its last state's, young, and still resolving is not rebuilt
def is-current-cases []: nothing -> nothing {
    let fixture = $env.PWD | path join current
    rm --recursive --force $fixture
    let c = context-default | merge {
        cache: ($fixture | path join cache), pacman_dbpath: ($fixture | path join dbpath), pacman_conf: ($fixture | path join pacman.conf)
        stage_links: ($fixture | path join stage), stage_db: ($fixture | path join stage lsck0.db.tar.gz)
    }
    mkdir ($c.cache | path join state) ($c.pacman_dbpath | path join sync) $c.stage_links
    write-lines $c.pacman_conf ["[options]" "Architecture = auto" "SigLevel = Never" $"[($REPO)]" $"Server = file://($c.stage_links)"]
    let tool = package-make $c.stage_links tool 1-1.2
    let broken = package-make $c.stage_links broken 1-1.1 ["depend = nothing-provides-this"]
    ^repo-add -q $c.stage_db $tool $broken e>| ignore
    ^cp $c.stage_db ($c.pacman_dbpath | path join sync lsck0.db)
    let n = night-empty | upsert db_file (db-index $c.stage_db)
    let key = "" | fill -c "a" -w 64
    let state = $c.cache | path join state
    let old_s = (date now | into int) // 1_000_000_000 - $FULL_REBUILD_DAYS * $SECONDS_PER_DAY
    # <case> <base> <state lines> <key now> <current>
    let cases = [
        [name base state key current];
        ["the last build of an unchanged recipe is current" tool [$"key=($key)" "build=2" $"built=(now-s)" "names=tool" "files=tool-1-1.2-any.pkg.tar.zst"] $key true]
        ["a changed recipe rebuilds" tool [$"key=($key)" "build=2" $"built=(now-s)" "names=tool" "files=tool-1-1.2-any.pkg.tar.zst"] ("" | fill -c "b" -w 64) false]
        ["a build FULL_REBUILD_DAYS old rebuilds" tool [$"key=($key)" "build=2" $"built=($old_s)" "names=tool" "files=tool-1-1.2-any.pkg.tar.zst"] $key false]
        ["a build the staged db does not serve rebuilds (a held back night)" tool [$"key=($key)" "build=3" $"built=(now-s)" "names=tool" "files=tool-1-1.3-any.pkg.tar.zst"] $key false]
        ["a name of the base the staged db lacks rebuilds" tool [$"key=($key)" "build=2" $"built=(now-s)" "names=tool tool-doc" "files=tool-1-1.2-any.pkg.tar.zst"] $key false]
        ["a build that no longer resolves rebuilds (a soname bump)" broken [$"key=($key)" "build=1" $"built=(now-s)" "names=broken" "files=broken-1-1.1-any.pkg.tar.zst"] $key false]
        ["a base without state builds" nostate [] $key false]
    ]
    for case in $cases {
        rm --recursive --force $state
        mkdir $state
        if ($case.state | is-not-empty) { write-lines ($state | path join $case.base) $case.state }
        let got = is-current $c $n $case.base $case.key
        if $got != $case.current { fail $"($case.name): current ($got)" }
        pass $case.name
    }
}

# a held back night's signed build in the pool is staged again for the same recipe, never for another or without its
# signature
def restage-cases []: nothing -> nothing {
    let fixture = $env.PWD | path join restage
    let key = "" | fill -c "d" -w 64
    let file = "tool-1-1.2-any.pkg.tar.zst"
    # <case> <key now> <signature present> <staged>
    let cases = [
        [name key signed staged];
        ["the same recipe stages its signed build from the pool again" $key true true]
        ["another recipe does not" ("" | fill -c "e" -w 64) true false]
        ["a build without its signature does not" $key false false]
    ]
    for case in $cases {
        rm --recursive --force $fixture
        let c = context-default | merge {
            cache: ($fixture | path join cache), repo_dir: ($fixture | path join served), outbox_pool: ($fixture | path join outbox)
            stage_db: ($fixture | path join cache db lsck0.db.tar.gz), stage_links: ($fixture | path join links)
            pacman_sync: ($fixture | path join sync)
        }
        mkdir ($c.cache | path join state) ($c.cache | path join db) $c.repo_dir $c.outbox_pool $c.pacman_sync
        ^bsdtar -czf $c.stage_db --files-from /dev/null
        package-make $c.repo_dir tool 1-1.2 | ignore
        if $case.signed { touch ($c.repo_dir | path join $"($file).sig") }
        state-set ($c.cache | path join state) tool $key 2 [tool] [$file]
        let n = restage $c (night-empty) tool $case.key
        let staged = $n != null and ($n.db_file | get -o tool) == $file
        if $staged != $case.staged { fail $"($case.name): staged ($staged)" }
        if $staged and (^readlink ($c.stage_links | path join $file) | str trim) != ($c.repo_dir | path join $file) {
            fail $"($case.name): the builder's pool does not lead to the served file"
        }
        pass $case.name
    }
}

# publish's acceptance of one rebuilt base: "" or the reason it keeps its served build
def base-check-cases []: nothing -> nothing {
    let fixture = $env.PWD | path join accept
    let key = "" | fill -c "c" -w 64
    let file = "tool-1-1.2-any.pkg.tar.zst"
    let state = {|lines| $lines | default [$"key=($key)" "build=2" "built=0" "names=tool" $"files=($file)"] }
    # <case> <outbox state lines, null for the good one> <change to the fixture> <publish state> <reason, "" to accept>
    let cases = [
        [name state change p reason];
        ["a rebuilt base with a new build of its own name is accepted" null {|c| } {} ""]
        ["a reused build number is refused" [$"key=($key)" "build=1" "built=0" "names=tool" $"files=($file)"] {|c| } {} "build 1 does not follow 1"]
        ["a build number that is no number is refused" [$"key=($key)" "build=2a" "built=0" "names=tool" $"files=($file)"] {|c| } {} "build 2a does not follow 1"]
        ["a recipe key that is no sha256 is refused" ["key=x" "build=2" "built=0" "names=tool" $"files=($file)"] {|c| } {} "recipe key 'x'"]
        ["another base's name is refused" null {|c| } {owner_of: {tool: other}} "tool belongs to other"]
        ["an aur recipe over an official name is refused" null {|c| } {official_name: {tool: true}} "tool is an official package"]
        ["a local recipe over an official name is accepted" null {|c| write-lines ($c.dotfiles | path join mirror pkgbuilds tool PKGBUILD) [pkgname=tool] } {official_name: {tool: true}} ""]
        ["a file name a path could hide in is refused" [$"key=($key)" "build=2" "built=0" "names=tool" "files=../tool-1-1.2-any.pkg.tar.zst"] {|c| } {} "file name '../tool-1-1.2-any.pkg.tar.zst'"]
        ["a file a signed state names already is refused" null {|c| touch ($c.repo_dir | path join $file) } {state_file: {$file: tool}} "exists in the pool already"]
        ["a file a killed publish left unreferenced is overwritten" null {|c| touch ($c.repo_dir | path join $file) } {} ""]
        ["a file missing from the outbox is refused" null {|c| rm ($c.outbox_pool | path join $file) } {} "is not in the outbox"]
        ["a link in the outbox is refused" null {|c| let f = $c.outbox_pool | path join $file; ^mv $f $"($f).real"; ^ln -s $"($f).real" $f } {} "is not in the outbox"]
        ["a file whose .PKGINFO names another version is refused" null {|c| package-make $c.outbox_pool tool 1-1.3 [] $file | ignore } {} "is tool-1-1.3-any inside"]
        ["a file of a name the base does not declare is refused" [$"key=($key)" "build=2" "built=0" "names=tool" "files=tool-doc-1-1.2-any.pkg.tar.zst"]
            {|c| package-make $c.outbox_pool tool-doc 1-1.2 | ignore } {} "is tool-doc, which is not an open name of tool"]
        ["a declared name without a file is refused" [$"key=($key)" "build=2" "built=0" "names=tool tool-doc" $"files=($file)"] {|c| } {} "no file for tool-doc"]
        ["an aur build that replaces an official package is refused" null {|c| package-make $c.outbox_pool tool 1-1.2 ["replaces = glibc>=2"] | ignore } {official_name: {glibc: true}} "replaces the official glibc"]
        ["a local build may replace an official package" null {|c|
            write-lines ($c.dotfiles | path join mirror pkgbuilds tool PKGBUILD) [pkgname=tool]
            package-make $c.outbox_pool tool 1-1.2 ["replaces = glibc"] | ignore
        } {official_name: {glibc: true}} ""]
    ]
    for case in $cases {
        rm --recursive --force $fixture
        let c = context-default | merge {
            outbox_state: ($fixture | path join outbox state), outbox_pool: ($fixture | path join outbox pool)
            repo_dir: ($fixture | path join served x86_64), served_state: ($fixture | path join served .state)
            dotfiles: ($fixture | path join dotfiles)
        }
        mkdir $c.outbox_state $c.outbox_pool $c.repo_dir $c.served_state $c.dotfiles ($fixture | path join check)
        write-lines ($c.outbox_state | path join tool) (do $state $case.state)
        write-lines ($c.served_state | path join tool) ["key=0" "build=1" "built=0" "names=tool" "files=tool-1-1.1-any.pkg.tar.zst"]
        package-make $c.outbox_pool tool 1-1.2 | ignore
        do $case.change $c
        let p = publish-empty | merge $case.p
        let got = base-check $c $p tool ($fixture | path join check)
        if ($case.reason == "") != ($got == "") or not ($got | str contains $case.reason) { fail $"($case.name): '($got)'" }
        pass $case.name
    }
}

# the newest, the first of the month, the first of the week (Monday) and the one current names stay; the pool always
def snapshot-prune-cases []: nothing -> nothing {
    let root = $env.PWD | path join prune-tree
    # a Sunday: the week started 2026-10-12, the month 2026-10-01
    let run = ("2026-10-18T03:00:00Z" | into datetime | into int) // 1_000_000_000
    let cases = [
        [name days current want];
        ["month, week and newest" [09-28 10-02 10-05 10-12 10-13 10-17 10-18] 10-18 [10-02 10-12 10-18]]
        ["current held back stays" [09-28 10-02 10-12 10-13 10-17] 09-28 [09-28 10-02 10-12 10-17]]
        ["one snapshot this month is all three" [09-20 09-30 10-18] 10-18 [10-18]]
        ["nothing this month keeps the newest" [09-20 09-30] 09-30 [09-30]]
    ]
    for case in $cases {
        rm --recursive --force $root
        for d in $case.days { mkdir ($root | path join $"2026-($d)" x86_64) }
        mkdir ($root | path join x86_64) ($root | path join public)
        ^ln -s $"2026-($case.current)" ($root | path join $CURRENT_NAME)
        snapshot-prune (context-default | merge {run_started: $run}) $root | ignore
        let kept = ls $root | where type == dir | get name | each { path basename } | sort
        let want = $case.want | each { $"2026-($in)" } | append [public x86_64] | sort
        if $kept != $want { fail $"($case.name): kept ($kept | to nuon), want ($want | to nuon)" }
        pass $"snapshot prune: ($case.name)"
    }
}

def db-index-cases []: nothing -> nothing {
    let dir = $env.PWD | path join index
    rm --recursive --force $dir
    mkdir ($dir | path join a-1-1) ($dir | path join b-1-1)
    "%FILENAME%\na-1-1-any.pkg.tar.zst\n\n%NAME%\na\n\n%VERSION%\n1-1\n\n" | save --force ($dir | path join a-1-1 desc)
    "%FILENAME%\nb-1-1-any.pkg.tar.zst\n\n%NAME%\nb\n\n%VERSION%\n1-1\n" | save --force ($dir | path join b-1-1 desc)
    ^bsdtar -czf index.db.tar.gz -C $dir .
    let got = db-index index.db.tar.gz
    if $got != {a: a-1-1-any.pkg.tar.zst, b: b-1-1-any.pkg.tar.zst} and $got != {b: b-1-1-any.pkg.tar.zst, a: a-1-1-any.pkg.tar.zst} {
        fail $"the db index is ($got | to nuon)"
    }
    pass "the db index maps every name to its file"
    "%NAME%\nc\n\n" | save --force ($dir | path join b-1-1 desc)
    ^bsdtar -czf index.db.tar.gz -C $dir .
    if (try { db-index index.db.tar.gz; true } catch { false }) { fail "a desc without its file was indexed" }
    pass "a desc without its file stops the index"
    "garbage" | save --force index.db.tar.gz
    if (try { db-index index.db.tar.gz; true } catch { false }) { fail "an unreadable db was indexed" }
    pass "an unreadable db stops the index"
}

def main [upstream: path, unavailable: int, aur_url: string, aur_state: path, pacman_upstream: path]: nothing -> nothing {
    let lib = $env.FILE_PWD | path join .. lib | path expand
    deps-check
    recipe-key-cases
    repack-cases
    is-current-cases
    restage-cases
    base-check-cases
    snapshot-prune-cases
    db-index-cases
    gate-check
    push-cases
    budget-check $unavailable
    outage-cases $lib $upstream $unavailable $aur_url $aur_state
    pool-cases $lib
    local-over-official $pacman_upstream "a local recipe newer than the official package serves its build (quickshell)" 0.3.2-1 0.3.2-2.9
    local-over-official $pacman_upstream "a local recipe older than the official package still serves its build" 0.3.2-5 0.3.2-2.9
    internet-cases $lib
    skip-cases $lib
}
