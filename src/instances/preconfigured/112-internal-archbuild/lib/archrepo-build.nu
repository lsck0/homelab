#!/usr/bin/env -S nu --no-config-file
# snapshot every package arch-dotfiles lists into the signed lsck0 pacman repo
#
# usage: archrepo-build.nu build|publish, each in a fresh archlinux container after archrepo-fetch.nu checked out a
# dotfiles commit signed by the pinned key (main.nix):
#   build    untrusted: runs aur and local recipes, holds no secret, cannot write the served tree. Its result is a
#            proposal in /outbox: unsigned packages, the staged db, the official dbs it ran against, state and a report.
#   publish  trusted: holds the repo and push keys and never runs or installs what a recipe produced. It signs only
#            proposed packages it can vouch for, builds the served db itself and publishes it as a dated snapshot.
#
# Security: a malicious recipe can ship bad contents under its own names, which installing it grants anyway, but
# cannot take the key, sign another base's name, take or replace an official package, or write the served tree:
#   - a rebuilt base advances its build number; its files are new, named after their .PKGINFO, and carry only names
#     the base owns already or nobody owns
#   - only a local recipe (signed dotfiles) may take or replace the name of an official package
#   - every served name maps to a file of a base's signed state, the file it serves already, or the file arch's dbs
#     name for it, which pacman checks against arch's keyring here
#   - a base that fails these checks keeps its served build; the rest of the night publishes
# The builder can still withhold or roll back (drop names, hold a night back, point an official name at an older
# arch-signed build); all of that shows in the status and none of it forges.
#
# Mounts:
#   /repo        served tree on the nas: <date>/x86_64 snapshots, current -> the newest, x86_64/ the pool of signed
#                files plus the newest db, status.{txt,json}, .state/, and the internet's tree in <prefix>/ (hardlinks
#                of the pool, its db without the official names: arch's mirrors serve those); read-only for build
#   /dotfiles    the verified arch-dotfiles checkout, read-only
#   /outbox      build writes it, publish reads it read-only
#   /cache       build only: pacman cache, sources, cargo and go caches, the staging db
#   /public      the builder's status page (logs/<base>.log, status.json, the host's build.log); publish pushes logs
#   /run/signing.asc, /run/push-key   publish only
#   /upstream, /run/archbuild.unavailable   modules/upstream's run, and where a skipped night names the upstream
#
# Packages keep their names; built ones are repacked to pkgrel 1.<n>, n counting the builds of that base, so a rebuild
# never reuses a file name a client may have cached. A base rebuilds when its recipe hash changes (aur commit, local
# PKGBUILD, a -git source's head via pkgver()), its build is FULL_REBUILD_DAYS old, or it no longer resolves against
# today's repos (soname bumps). The official closure is copied at the versions the builds ran against, and the served
# db is replaced only when the set resolves from [lsck0] alone; otherwise the night is held back. Crash-only: all
# state is per base, a killed run is picked up by the next one.
#
# Completeness: every listed name must stay installable from the served snapshot. A failed base keeps its last build
# while that still resolves (a base gone from the aur too). A night that would lose a listed name the served db
# provides is held back, for COMPLETENESS_HOLD_DAYS at most, since a lost name whose build no longer resolves would
# otherwise freeze every official update. A name never served does not hold back; it shows in status `missing`.
#
# Outages: every call to the aur, the official mirrors and github goes through modules/upstream, which retries it;
# while one stays down the night ends with UNAVAILABLE before anything is proposed. A keyserver outage defers only the
# recipes with validpgpkeys. Time: a recipe that could end past ARCHBUILD_BUILD_BUDGET_S waits for the next night,
# so the snapshot and the publish fit the unit's timeout.

export const REPO = "lsck0"
export const ARCH = "x86_64"
export const DB_FILES = ["lsck0.db.tar.gz" "lsck0.files.tar.gz"]
export const CURRENT_NAME = "current"
export const SNAPSHOT_MANIFEST = "manifest.json"
const SNAPSHOT_PATTERN = '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
# one or more path segments, never one that climbs or hides
const INTERNET_PREFIX_PATTERN = '^(/[A-Za-z0-9_~-][A-Za-z0-9._~-]*)+$'
# a snapshot hardlinks the pool, so a kept one costs only the files new since the one before it
export const LOGS_NAME = "logs"
export const BUILD_LOG_NAME = "build.log"
# a log above it is a runaway build: it stays on vm-112 and off the mirror's disk
const LOG_PUSH_SIZE_MAX = "64M"
const PUSH_CONNECT_TIMEOUT_S = 15
export const OFFICIAL_REPOS = [core extra multilib]
const BUILDER = "builder"
# the uid every writing container on the nas uses
const BUILDER_UID = 1000
# soname bumps on a rolling distro break old builds without a version change
export const FULL_REBUILD_DAYS = 14
export const SECONDS_PER_DAY = 86400
# per recipe, so one hung build cannot eat the night
const BUILD_TIMEOUT_S = 10800
const FETCH_TIMEOUT_S = 900
const BUILD_KILL_AFTER_S = 300
const FETCH_KILL_AFTER = "1m"
# the longest one recipe may take, its dependency installs included
export const RECIPE_BOUND_S = $BUILD_TIMEOUT_S + $BUILD_KILL_AFTER_S + $FETCH_TIMEOUT_S
# a whole night's official downloads, several GiB after a gap; pacman drops a stalled connection itself
const PACMAN_TRANSFER_TIMEOUT_S = 7200
const HTTP_TIMEOUT_S = 60
# modules/upstream's unavailable (tests/archrepo_build_test.nu holds them equal)
export const UNAVAILABLE = 75
# a recipe's validpgpkeys come from here; makepkg fails a build whose key is missing
const KEYSERVER = "hkps://keyserver.ubuntu.com"
const KEY_FETCH_TIMEOUT_S = 120
const NINJA_WRAPPER = "/usr/local/bin/ninja"
const RESOLVE_ROUNDS_MAX = 16
# names per aur rpc request
const RPC_BATCH = 100
const CACHE_KEEP_DAYS = 30
# an expired go build cache entry costs one cold compile; kept forever it grows without bound on the 98 GiB disk
const BUILD_CACHE_KEEP_DAYS = 14
# part of every rebuild key: bump it when repack changes what a published package contains
export const REPACK_VERSION = 3
const PKGBUILDS = "mirror/pkgbuilds"
# dependencies aur recipes forget: <pkgbase> <depends|makedepends> <package>...
const OVERRIDES = "mirror/overrides.conf"
# the public half of the repo key, which clients trust; its uid is the packager
const REPO_PUBLIC_KEY = "configs/base/pacman/archrepo.asc"
# the 2026 naming served lsck0-<name>; replaces lets a pacman -Syu swap the installed ones over
const OLD_PREFIX = "lsck0-"
const AUR_URL = "https://aur.archlinux.org"
const USER_AGENT = "lsck0-archbuild (https://github.com/lsck0/arch-dotfiles)"
# makepkg's pkgname rule: alphanumerics and @._+-, not starting with a hyphen or a dot
export const NAME_PATTERN = '^[a-z0-9@_+][a-z0-9@._+-]*$'
# <name>-<epoch:version>-<release>-<arch>.pkg.tar.zst, nothing a path could hide in
const FILE_PATTERN = '^[a-z0-9@_+][a-z0-9@._+-]*-[A-Za-z0-9.:_+~]+-[0-9.]+-(x86_64|any)\.pkg\.tar\.zst$'
const KEY_PATTERN = '^[0-9a-f]{64}$'
# the head of a desc: its file, a blank line, its name
const DESC_HEAD_PATTERN = '(?m)^%FILENAME%\n(?P<value>[^\n]*)\n\n%NAME%\n(?P<key>[^\n]+)$'
const VCS_SOURCE_PATTERN = '^\s*source(_x86_64)? = ([^ ]*::)?(git|hg|svn|bzr|fossil)\+'
# two nights to fix the list or the recipe before a lost listed name stops holding official updates back
export const COMPLETENESS_HOLD_DAYS = 3
const HELD_BACK_QUOTE_MAX = 300
const TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
const DATE_FORMAT = "%Y-%m-%d"
const NANOSECONDS_PER_SECOND = 1_000_000_000

# every path and setting of a run; the tests override single fields
export def context-default []: nothing -> record {
    let served = "/repo"
    let cache = "/cache"
    let outbox = "/outbox"
    let public = "/public"
    let prefix = $env.ARCHBUILD_INTERNET_PREFIX? | default ""
    let started = $env.ARCHBUILD_RUN_STARTED? | default "0" | into int
    {
        served: $served
        repo_dir: ($served | path join $ARCH)
        served_state: ($served | path join .state)
        snapshot_current: ($served | path join $CURRENT_NAME)
        internet_prefix: $prefix
        internet_served: $"($served)($prefix)"
        cache: $cache
        # the staging db, rebuilt from the served one every run
        stage_db: ($cache | path join db $"($REPO).db.tar.gz")
        # the builder's pacman installs staged packages from here: a link per staged file into the outbox or the pool
        stage_links: ($cache | path join stage-links)
        public: $public
        public_logs: ($public | path join $LOGS_NAME)
        build_log: ($public | path join $BUILD_LOG_NAME)
        log_push_size_max: $LOG_PUSH_SIZE_MAX
        dotfiles: "/dotfiles"
        outbox: $outbox
        outbox_pool: ($outbox | path join pool)
        outbox_sync: ($outbox | path join sync)
        outbox_state: ($outbox | path join state)
        outbox_db: ($outbox | path join $"($REPO).db.tar.gz")
        outbox_report: ($outbox | path join report.json)
        # written last by build: publish takes only the outbox of its own run
        outbox_run: ($outbox | path join run)
        # publish's scratch space, inside its container
        work: "/var/tmp/archbuild"
        signing_key_file: "/run/signing.asc"
        # empty disables the push
        push_target: ($env.ARCHBUILD_PUSH_TARGET? | default "")
        push_key_file: "/run/push-key"
        # the lab's host keys: the mirror proves itself before the push key is offered
        push_known_hosts_file: "/run/known_hosts"
        source: ($env.ARCHBUILD_SOURCE? | default "")
        ref: ($env.ARCHBUILD_REF? | default "")
        commit: ($env.ARCHBUILD_COMMIT? | default "")
        # epoch seconds the unit started at: the run id, the snapshot date and the age archbuild-if-stale reads
        run_started: $started
        build_budget_s: ($env.ARCHBUILD_BUILD_BUDGET_S? | default "" )
        build_deadline: ($started + ($env.ARCHBUILD_BUILD_BUDGET_S? | default "0" | into int))
        recipe_bound_s: $RECIPE_BOUND_S
        jobs: ($env.ARCHBUILD_JOBS? | default "")
        # the container's own pacman state; the tests point it into the sandbox
        pacman_dbpath: "/var/lib/pacman"
        pacman_sync: "/var/lib/pacman/sync"
        pacman_conf: "/etc/pacman.conf"
        upstream: "/upstream"
        unavailable_file: "/run/archbuild.unavailable"
        # prints the package list of a dotfiles checkout, mounted next to this script
        list_script: "/list.nu"
        aur_url: $AUR_URL
        # a command prefix: timeout runs it
        as_builder: [sudo -u $BUILDER -H env $"CARGO_HOME=($cache)/cargo" $"GOPATH=($cache)/go"
            $"GOMODCACHE=($cache)/go/mod" $"GOCACHE=($cache)/go/build"]
        key: ""
    }
}

# the build's mutable state, threaded through every step
export def night-empty []: nothing -> record {
    {
        kind: {}, bases: [], names: {}, deps: {}, provider: {}, failed: {}, listed: {}, repo_has: {}, db_file: {}
        looked_up: {}, order: [], aur_wanted: [], official_wanted: [], official_names: [], built: [], dropped: []
        # empty while the staged set is publishable, else why the night is held back
        held_back: ""
        # prune only when every base is known, a transient fetch error must not delete packages
        resolve_complete: true
    }
}

# publish's state: the served db (name -> file), the signed state (file -> name, name -> base), arch's names today,
# and the db it serves next (name -> file)
export def publish-empty []: nothing -> record {
    {
        served: {}, state_file: {}, owner_of: {}, official_name: {}, final: {}, internet_files: [], built: [], failed: {}
        held_back: "", snapshot_missing: [], proposed_missing: [], push_failed: false
    }
}

# -----------------------------------------------------------------------------
# INTERNAL
# -----------------------------------------------------------------------------

export def log [message: string]: nothing -> nothing {
    print $"(date now | date to-timezone UTC | format date '%H:%M:%S') ($message)"
}

def die [message: string]: nothing -> nothing {
    log $message
    exit 1
}

def time-format [seconds: int, format: string]: nothing -> string {
    $seconds * $NANOSECONDS_PER_SECOND | into datetime | date to-timezone UTC | format date $format
}

def now-s []: nothing -> int {
    (date now | into int) // $NANOSECONDS_PER_SECOND
}

# a set or a map from a list of keys or {key, value} rows; later rows win
export def to-set []: list<string> -> record {
    each {|key| {key: $key, value: true} } | to-map
}

export def to-map []: list<record<key: string, value: any>> -> record {
    let rows = $in | reverse | uniq-by key
    if ($rows | is-empty) { {} } else { $rows | rename key value | transpose -r -d }
}

def has [set: record, key: string]: nothing -> bool {
    ($set | get -o $key) != null
}

export def fail [n: record, base: string, reason: string]: nothing -> record {
    log $"FAIL ($base): ($reason)"
    $n | upsert failed ($n.failed | upsert $base $reason)
}

export def failures-list [failed: record]: nothing -> list<string> {
    $failed | items {|base, reason| $"($base): ($reason)" }
}

# a status, streaming the command's output; a command that never started counts as 1
def --wrapped command-status [...argv: string]: nothing -> int {
    try { ^$argv.0 ...($argv | skip 1); 0 } catch {|err| $err.exit_code? | default 1 }
}

def --wrapped command-logged [log_file: path, ...argv: string]: nothing -> int {
    try { ^$argv.0 ...($argv | skip 1) o+e>> $log_file; 0 } catch {|err| $err.exit_code? | default 1 }
}

# an outage of a third party skips the whole night: nothing is proposed or published, the served snapshot stays
def night-skip [c: record, upstream: string]: nothing -> nothing {
    log $"($upstream) unavailable, skipping the night"
    $upstream | save --force $c.unavailable_file
    exit $UNAVAILABLE
}

# <upstream> <command...> through modules/upstream; its outage ends the run here
export def --wrapped upstream-call [c: record, timeout_s: int, upstream: string, ...argv: string]: nothing -> int {
    let status = with-env {UPSTREAM_TIMEOUT_S: ($timeout_s | into string)} { command-status bash $c.upstream $upstream ...$argv }
    if $status == $UNAVAILABLE { night-skip $c $upstream }
    $status
}

# the same with the command's stdout dropped, its errors still shown
def --wrapped upstream-quiet [c: record, timeout_s: int, upstream: string, ...argv: string]: nothing -> int {
    let status = with-env {UPSTREAM_TIMEOUT_S: ($timeout_s | into string)} {
        try { ^bash $c.upstream $upstream ...$argv o> /dev/null; 0 } catch {|err| $err.exit_code? | default 1 }
    }
    if $status == $UNAVAILABLE { night-skip $c $upstream }
    $status
}

def --wrapped upstream-logged [c: record, log_file: path, timeout_s: int, upstream: string, ...argv: string]: nothing -> int {
    let status = with-env {UPSTREAM_TIMEOUT_S: ($timeout_s | into string)} {
        command-logged $log_file bash $c.upstream $upstream ...$argv
    }
    if $status == $UNAVAILABLE { night-skip $c $upstream }
    $status
}

# the aur's answer to <url>, null when the call failed; every retry rewrites the answer whole
def aur-get [c: record, url: string, ...args: string]: nothing -> any {
    let answer = $c.cache | path join aur-answer.json
    let status = upstream-call $c $HTTP_TIMEOUT_S aur curl -fsSL --max-time ($HTTP_TIMEOUT_S | into string) -A $USER_AGENT -o $answer ...$args $url
    if $status != 0 { return null }
    let parsed = try { open --raw $answer | from json } catch { null }
    # an answer without results fails like jq's .results[] did: the build's own rpc failure
    if ($parsed | describe) !~ '^record' or ($parsed.results? | describe) !~ '^(list|table)' { return null }
    $parsed
}

# .SRCINFO values of one key, arch-specific ones included
export def srcinfo-get [file: path, key: string]: nothing -> list<string> {
    open --raw $file | lines | each { str trim --left | split row --regex '\s+' } | where {|words|
        ($words | length) >= 3 and ($words.0 == $key or $words.0 == $"($key)_x86_64") and $words.1 == "="
    } | each { get 2 }
}

def version-strip []: string -> string {
    str replace --regex '[<>=].*' ''
}

# one field of a base's state file, "" for a base without one
export def state-get [dir: path, base: string, key: string]: nothing -> string {
    let file = $dir | path join $base
    if not ($file | path exists) { return "" }
    open --raw $file | lines | where { str starts-with $"($key)=" } | each { str substring (($key | str length) + 1).. }
    | str join "\n"
}

def state-words [dir: path, base: string, key: string]: nothing -> list<string> {
    state-get $dir $base $key | split row " " | where $it != ""
}

export def state-set [dir: path, base: string, key: string, build: int, names: list<string>, files: list<string>]: nothing -> nothing {
    let tmp = $dir | path join $".($base).tmp"
    [$"key=($key)" $"build=($build)" $"built=(now-s)" $"names=($names | str join ' ')" $"files=($files | str join ' ')"]
    | str join "\n" | $"($in)\n" | save --force $tmp
    mv --force $tmp ($dir | path join $base)
}

# copy then rename, a reader never sees half a file
export def put [file: path, dir: path, name?: string]: nothing -> nothing {
    let name = $name | default ($file | path basename)
    ^cp $file ($dir | path join $".($name).tmp")
    ^mv -f ($dir | path join $".($name).tmp") ($dir | path join $name)
}

# hardlink then rename: the same file under a second name, swapped in whole
def link-into [file: path, dir: path]: nothing -> nothing {
    let name = $file | path basename
    ^ln -f $file ($dir | path join $".($name).tmp")
    ^mv -f ($dir | path join $".($name).tmp") ($dir | path join $name)
}

# symlink then rename, so the old link is never missing for a moment
def symlink-set [target: string, link: path]: nothing -> nothing {
    let tmp = $link | path dirname | path join $".($link | path basename).tmp"
    ^ln -sfn $target $tmp
    ^mv -fT $tmp $link
}

# a detached signature next to the file, renamed into place only once it verifies
export def sign [c: record, file: path]: nothing -> nothing {
    let tmp = $file | path dirname | path join $".($file | path basename).sig.tmp"
    ^gpg --batch --yes --detach-sign --no-armor -u $c.key -o $tmp $file
    let verified = do { ^gpg --batch --verify $tmp $file } | complete
    if $verified.exit_code != 0 { error make {msg: $"the signature of ($file) does not verify"} }
    ^mv -f $tmp $"($file).sig"
}

# the staged packages of these names against today's official repos and the staging db: by name alone pacman's repo
# order would check an official package of the same name in their place
def names-resolve [c: record, names: list<string>]: nothing -> bool {
    let targets = $names | each { $"($REPO)/($in)" }
    (do { ^pacman --config $c.pacman_conf --dbpath $c.pacman_dbpath -Sp --noconfirm ...$targets } | complete).exit_code == 0
}

def pkginfo-get [pkginfo: string, field: string]: nothing -> list<string> {
    $pkginfo | lines | where { str starts-with $"($field) = " } | each { str substring (($field | str length) + 3).. }
}

# the package name of a <name>-<version>-<release>-<arch>.pkg.tar.zst file name
export def file-package-name [file: string]: nothing -> string {
    $file | str replace --regex '-[^-]*-[^-]*-[^-]*$' ''
}

# a regular file in the outbox, never a link into something the reader's mounts hold
def outbox-file-check [file: path]: nothing -> bool {
    ($file | path type) == file
}

# listed names <db> provides neither as a name, a provides nor a group; without a db, every listed name
export def listed-missing [c: record, db?: path]: nothing -> list<string> {
    let db_args = if $db != null and ($db | path exists) { [$db] } else { [] }
    let got = do { ^$nu.current-exe --no-config-file $c.list_script $c.dotfiles ...$db_args } | complete
    print -e -n $got.stderr
    if $got.exit_code != 0 { error make {msg: "reading the package list failed"} }
    $got.stdout | lines | where $it != ""
}

def json-replace [file: path, value: any]: nothing -> nothing {
    $value | to json --indent 2 | save --force $"($file).new"
    mv --force $"($file).new" $file
}

# -----------------------------------------------------------------------------
# REPO
# -----------------------------------------------------------------------------

# name -> file of a db; a db that cannot be read stops the caller, an empty index would look like an empty repo.
# repo-add starts every desc with %FILENAME% and %NAME%; a desc that does not is no db this pipeline wrote
export def db-index [db: path]: nothing -> record {
    let got = do { ^bsdtar -xOf $db } | complete
    if $got.exit_code != 0 { error make {msg: $"cannot read ($db)"} }
    let index = $got.stdout | parse --regex $DESC_HEAD_PATTERN
    let names = $got.stdout | parse --regex '(?m)^(%NAME%)$' | length
    if ($index | length) != $names { error make {msg: $"($db) has a desc without its file or name"} }
    $index | select key value | to-map
}

# the served db pair copied into <dir>, an empty pair on a first run
def db-copy-served [c: record, dir: path]: nothing -> nothing {
    mkdir $dir
    for f in $DB_FILES {
        let served = $c.repo_dir | path join $f
        if ($served | path exists) { ^cp $served ($dir | path join $f) } else {
            ^bsdtar -czf ($dir | path join $f) --files-from /dev/null
        }
    }
}

# a fresh pacman dbpath with an empty local db and a sync/ to fill
def dbpath-create [dir: path]: nothing -> nothing {
    rm --recursive --force $dir
    mkdir ($dir | path join sync)
}

# -----------------------------------------------------------------------------
# BUILD: SETUP
# -----------------------------------------------------------------------------

# one link per staged file into the pool that holds it, the outbox's own build before the served copy: the builder's
# pacman reads one server, which holds every file the staged db names; a name without a file stops the run
export def stage-links-sync [c: record, db_file: record]: nothing -> nothing {
    mkdir $c.stage_links
    for row in ($db_file | transpose name file) {
        let link = $c.stage_links | path join $row.file
        # a file name is one content wherever it lies: a link that still resolves stays
        if ($link | path exists) { continue }
        let target = [$c.outbox_pool $c.repo_dir] | each { path join $row.file } | where { ($in | path type) == file }
        if ($target | is-empty) {
            die $"the staged db names ($row.file) for ($row.name), which neither ($c.outbox_pool) nor ($c.repo_dir) holds"
        }
        ^ln -sfn ($target | first) $link
    }
}

# the builder's pacman reads the staging db, so later builds and the resolve checks see what is staged
export def db-sync-local [c: record, n: record]: nothing -> record {
    ^cp $c.stage_db ($c.pacman_sync | path join $"($REPO).db")
    let db_file = db-index $c.stage_db
    stage-links-sync $c $db_file
    $n | upsert db_file $db_file
}

def setup-build [c: record]: nothing -> nothing {
    if (do { ^id $BUILDER } | complete).exit_code != 0 { ^useradd -m -u $BUILDER_UID $BUILDER }
    # regenerated every run; a stale recipe would linger as a base that is no longer wanted
    rm --recursive --force ...([build out recipes] | each {|dir| $c.cache | path join $dir }) $c.stage_links
    let owned = [src build recipes out cargo go] | each {|dir| $c.cache | path join $dir }
    mkdir ...$owned ...([pacman aur stage] | each {|dir| $c.cache | path join $dir }) $c.public_logs
    ^chown $"($BUILDER):" ...$owned
    # a killed run's proposal must never be read as this run's
    ^find $c.outbox -mindepth 1 -delete
    mkdir $c.outbox_pool $c.outbox_sync
    let state = $c.cache | path join state
    rm --recursive --force $state
    mkdir $state
    if ($c.served_state | path exists) { ^cp -a $"($c.served_state)/." $"($state)/" }
    let key = $c.dotfiles | path join $REPO_PUBLIC_KEY
    let packager = ^gpg --show-keys --with-colons $key | lines | each { split row ":" } | where { $in.0 == uid }
    | get -o 0.9
    if $packager == null { die $"no key uid in ($key)" }
    # main.nix sizes the jobs to the balloon floor and the cpuset to them, so cargo and go agree
    if $c.jobs == "" { die "ARCHBUILD_JOBS is unset: compile jobs within the balloon floor" }
    [
        $"MAKEFLAGS=\"-j($c.jobs)\""
        $"BUILDDIR=($c.cache)/build"
        "OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)"
        $"PACKAGER=\"($packager)\""
    ] | str join "\n" | $"($in)\n" | save --force /etc/makepkg.conf.d/archbuild.conf
    # ninja reads no MAKEFLAGS and runs nproc + 2; cmake and meson find it first on PATH, a recipe's own -j still wins
    $"#!/bin/sh\nexec /usr/bin/ninja -j($c.jobs) \"$@\"\n" | save --force $NINJA_WRAPPER
    ^chmod 755 $NINJA_WRAPPER
}

# the container's entry (main.nix) set up arch's keyring, multilib and the cache, and ran the run's only sync: builds and
# the snapshot resolve against one state of the official repos
def setup-build-pacman [c: record, n: record]: nothing -> record {
    let installed = upstream-quiet $c $PACMAN_TRANSFER_TIMEOUT_S archlinux pacman -S --noconfirm --needed git expac
    if $installed != 0 { die "installing the build tools failed" }
    # added after the sync, which would look for a served db, and after the official repos, so staged copies of
    # official packages never shadow today's versions; SigLevel Never: these are this container's own unsigned builds
    $"\n[($REPO)]\nSigLevel = Never\nServer = file://($c.stage_links)\n" | save --append $c.pacman_conf
    let n = db-sync-local $c $n
    ^git config --global --add safe.directory "*"
    $n | upsert baseline (^pacman -Qq | lines)
}

# names, provides and groups of every official package
def repo-has-load [n: record]: nothing -> record {
    let has = ^expac -S -l " " "%r %n %S %G" | lines | each { split row " " } | where { $in.0 != $REPO }
    | each { skip 1 | each { str replace --regex '=.*' '' } } | flatten | where $it != "" | uniq
    $n | upsert repo_has ($has | to-set)
}

# -----------------------------------------------------------------------------
# BUILD: RECIPES
# -----------------------------------------------------------------------------

# a fetch into a kept repo, so a retried attempt starts over cleanly
export def recipe-aur [c: record, base: string, dir: path]: nothing -> bool {
    let clone = $c.cache | path join aur $base
    if not ($clone | path join .git | path exists) {
        rm --recursive --force $clone
        ^git init -q $clone
    }
    if (upstream-call $c $FETCH_TIMEOUT_S aur git -C $clone fetch -q $"($c.aur_url)/($base).git" master) != 0 { return false }
    if (command-status git -C $clone reset -q --hard FETCH_HEAD) != 0 { return false }
    (do { ^git -C $clone archive HEAD | ^tar -x -C $dir } | complete).exit_code == 0
}

def recipe-local [c: record, base: string, dir: path]: nothing -> bool {
    let recipe = $c.dotfiles | path join $PKGBUILDS $base
    if not ($recipe | path join PKGBUILD | path exists) { return false }
    ^cp -r $"($recipe)/." $"($dir)/"
    true
}

# appends the overrides of one base to its PKGBUILD; changed tells whether it touched it
def recipe-override [c: record, n: record, base: string, dir: path]: nothing -> record {
    let file = $c.dotfiles | path join $OVERRIDES
    if not ($file | path exists) { return {n: $n, changed: false} }
    let rows = open --raw $file | lines | each { str replace --regex '#.*' '' | str trim | split row --regex '\s+' }
    | where { $in.0 == $base }
    mut changed = false
    for row in $rows {
        let field = $row | get -o 1 | default ""
        if $field not-in [depends makedepends] {
            return {n: (fail $n $base $"unknown override field '($field)'"), changed: false}
        }
        $"\n($field)+=(($row | skip 2 | str join ' '))\n" | save --append ($dir | path join PKGBUILD)
        $changed = true
    }
    {n: $n, changed: $changed}
}

# a recipe dir with a PKGBUILD and its .SRCINFO; records names, provides and deps
def materialize [c: record, n: record, base: string]: nothing -> record {
    if $base !~ $NAME_PATTERN { return (fail $n $base "not a package base name") }
    let dir = $c.cache | path join recipes $base
    rm --recursive --force $dir
    mkdir $dir
    let kind = $n.kind | get $base
    let fetched = if $kind == aur { recipe-aur $c $base $dir } else { recipe-local $c $base $dir }
    if not $fetched { return (fail $n $base "fetching the recipe" | upsert resolve_complete false) }
    ^chown -R $"($BUILDER):" $dir
    # an aur .SRCINFO is shipped, and only stale once an override touched the PKGBUILD
    let override = if $kind == aur { recipe-override $c $n $base $dir } else { {n: $n, changed: true} }
    mut n = $override.n
    if $override.changed {
        let srcinfo = do { cd $dir; ^$c.as_builder.0 ...($c.as_builder | skip 1) makepkg --printsrcinfo } | complete
        if $srcinfo.exit_code != 0 {
            print -e -n $srcinfo.stderr
            return (fail $n $base "invalid PKGBUILD")
        }
        $srcinfo.stdout | save --force ($dir | path join .SRCINFO)
    }
    let srcinfo = $dir | path join .SRCINFO
    let names = srcinfo-get $srcinfo pkgname
    let deps = srcinfo-get $srcinfo depends | append (srcinfo-get $srcinfo makedepends) | each { version-strip } | sort | uniq
    let provides = srcinfo-get $srcinfo provides | each { str replace --regex '=.*' '' }
    let provider = $names | append $provides | each {|name| {key: $name, value: $base} } | to-map
    $n | merge {
        names: ($n.names | upsert $base $names)
        deps: ($n.deps | upsert $base $deps)
        provider: ($n.provider | merge $provider)
    }
}

export def base-add [c: record, n: record, base: string, kind: string]: nothing -> record {
    if (has $n.kind $base) { return $n }
    materialize $c ($n | merge {kind: ($n.kind | upsert $base $kind), bases: ($n.bases | append $base)}) $base
}

# -----------------------------------------------------------------------------
# BUILD: RESOLVE
# -----------------------------------------------------------------------------

def local-recipe-exists [c: record, name: string]: nothing -> bool {
    $c.dotfiles | path join $PKGBUILDS $name PKGBUILD | path exists
}

def lists-read [c: record, n: record]: nothing -> record {
    let list = try { listed-missing $c } catch { die $"reading the package list of ($c.dotfiles) failed" }
    mut n = $n | upsert listed ($list | to-set)
    for name in $list {
        if (local-recipe-exists $c $name) {
            $n = base-add $c $n $name local
        } else if (has $n.repo_has $name) {
            $n = $n | upsert official_wanted ($n.official_wanted | append $name)
        } else {
            $n = $n | upsert aur_wanted ($n.aur_wanted | append $name)
        }
    }
    $n
}

# name -> base for every name the aur has, null when an rpc failed
def aur-bases [c: record, names: list<string>]: nothing -> any {
    mut found = []
    for batch in ($names | chunks $RPC_BATCH) {
        let args = $batch | each {|name| [--data-urlencode $"arg[]=($name)"] } | flatten
        let answer = aur-get $c $"($c.aur_url)/rpc/v5/info" ...$args
        if $answer == null { return null }
        $found = $found | append ($answer.results | each {|r| {key: $r.Name, value: $r.PackageBase} })
    }
    $found | to-map
}

# the base providing name, "" when none does, null when the search failed
def aur-base-providing [c: record, name: string]: nothing -> any {
    let answer = aur-get $c $"($c.aur_url)/rpc/v5/search/($name | url encode --all)?by=provides"
    if $answer == null { return null }
    let exact = $answer.results | where Name == $name
    # jq's sort_by(-.NumVotes): stable, the aur's order kept among equal votes
    let voted = $answer.results | insert votes_negated {|r| 0 - ($r.NumVotes? | default 0) } | sort-by votes_negated
    $exact | append $voted | get -o 0.PackageBase | default ""
}

# a name the aur answered it lacks: the served base carrying it keeps its last build while that still resolves
# (a failed base, drop-unresolvable), so one deleted aur package does not freeze the official updates
def source-gone [c: record, n: record, name: string]: nothing -> record {
    let state = $c.cache | path join state
    let carrier = if ($state | path exists) { ls $state | get name | each { path basename } } else { [] }
    | where {|base| not (has $n.kind $base) and $name in (state-words $state $base names) } | get -o 0
    if $carrier == null {
        return (if (has $n.listed $name) { fail $n $name "not in the aur" } else { $n })
    }
    let names = state-words $state $carrier names
    let n = $n | merge {
        kind: ($n.kind | upsert $carrier gone)
        bases: ($n.bases | append $carrier)
        names: ($n.names | upsert $carrier $names)
        provider: ($n.provider | merge ($names | each {|carried| {key: $carried, value: $carrier} } | to-map))
    }
    fail $n $carrier "gone from the aur, its last build stays while it resolves"
}

def deps-unsatisfied [n: record, bases: list<string>]: nothing -> list<string> {
    $bases | each {|base| $n.deps | get -o $base | default [] } | flatten | where {|dep|
        not ((has $n.repo_has $dep) or (has $n.provider $dep) or (has $n.looked_up $dep))
    } | sort | uniq
}

# listed aur names plus every dependency neither the repos nor another base satisfies
export def resolve [c: record, n: record]: nothing -> record {
    mut n = $n
    mut pending = $n.aur_wanted | append (deps-unsatisfied $n $n.bases) | where $it != "" | sort | uniq
    mut round = 0
    while $round < $RESOLVE_ROUNDS_MAX and ($pending | is-not-empty) {
        # a local recipe wins for a dependency as for a listed name: the aur's copy may be the broken one it replaces
        mut new = []
        mut remote = []
        for name in $pending {
            if (local-recipe-exists $c $name) {
                if not (has $n.kind $name) {
                    $n = base-add $c $n $name local
                    $new = $new | append $name
                }
            } else {
                $remote = $remote | append $name
            }
        }
        let found = if ($remote | is-empty) { {} } else { aur-bases $c $remote }
        if $found == null {
            log "aur rpc failed"
            return ($n | upsert resolve_complete false)
        }
        for name in $remote {
            $n = $n | upsert looked_up ($n.looked_up | upsert $name true)
            mut base = $found | get -o $name | default ""
            if $base == "" and not (has $n.listed $name) {
                let providing = aur-base-providing $c $name
                if $providing == null {
                    log $"aur search for ($name) failed"
                    $n = $n | upsert resolve_complete false
                    continue
                }
                $base = $providing
            }
            # the rpc answered, so a name missing from it is gone for good and must not block pruning
            if $base == "" {
                $n = source-gone $c $n $name
                continue
            }
            if not (has $n.kind $base) {
                $n = base-add $c $n $base aur
                $new = $new | append $base
            }
        }
        $pending = deps-unsatisfied $n $new
        $round += 1
    }
    if ($pending | is-not-empty) {
        log $"dependency depth exceeds ($RESOLVE_ROUNDS_MAX)"
        $n = $n | upsert resolve_complete false
    }
    $n
}

# dependencies first into order; a base whose dependency nothing provides fails here
def plan [n: record]: nothing -> record {
    mut n = $n
    mut edges = []
    for base in $n.bases {
        $edges = $edges | append $"($base) ($base)"
        for dep in ($n.deps | get -o $base | default []) {
            let provider = $n.provider | get -o $dep
            if $provider != null {
                if $provider != $base { $edges = $edges | append $"($provider) ($base)" }
            } else if not (has $n.repo_has $dep) and not (has $n.failed $base) {
                $n = fail $n $base $"nothing provides ($dep)"
            }
        }
    }
    # a cycle still prints an order, tsort complains on stderr
    let order = $edges | str join "\n" | do { ^tsort } | complete | get stdout | lines | where $it != ""
    $n | upsert order $order
}

# -----------------------------------------------------------------------------
# BUILD: BUILD
# -----------------------------------------------------------------------------

def is-vcs [dir: path]: nothing -> bool {
    open --raw ($dir | path join .SRCINFO) | lines | any { $in =~ $VCS_SOURCE_PATTERN }
}

# the sha256 of "repack <n>" and sha256sum's lines over every file, sorted by path
export def recipe-key [dir: path]: nothing -> string {
    let sums = do {
        cd $dir
        let files = ^find . -type f -print0 | split row (char nul) | where $it != "" | sort
        ^sha256sum ...$files
    }
    $"repack ($REPACK_VERSION)\n($sums)\n" | hash sha256
}

export def is-current [c: record, n: record, base: string, key: string]: nothing -> bool {
    let state = $c.cache | path join state
    if $key != (state-get $state $base key) { return false }
    let built_at = state-get $state $base built | if $in == "" { 0 } else { $in | into int }
    if (now-s) - $built_at >= $FULL_REBUILD_DAYS * $SECONDS_PER_DAY { return false }
    let names = state-words $state $base names
    let files = state-words $state $base files
    # the staged file must be this build's, a held back or killed run leaves the previous one served
    if not ($names | all {|name| ($n.db_file | get -o $name) in $files }) { return false }
    # a soname bump in today's repos leaves the old build uninstallable
    names-resolve $c $names
}

# the depends and makedepends of a recipe dir, minus the names and provides its own packages give: a split base's
# meta package depends on its siblings (apparmor.d on apparmor.d-base), which only this build produces
export def build-deps-wanted [dir: path]: nothing -> list<string> {
    let srcinfo = $dir | path join .SRCINFO
    let own = srcinfo-get $srcinfo pkgname | append (srcinfo-get $srcinfo provides | each { version-strip }) | to-set
    srcinfo-get $srcinfo depends | append (srcinfo-get $srcinfo makedepends) | sort | uniq
    | where {|dep| not (has $own ($dep | version-strip)) }
}

# what makepkg -s would install, installed by root: the build user gets no pacman of its own
def build-deps-install [c: record, dir: path, log_file: path]: nothing -> bool {
    let wanted = build-deps-wanted $dir
    if ($wanted | is-empty) { return true }
    # -T prints the unsatisfied ones and exits 127 when there are any
    let missing = do { ^pacman -T ...$wanted } | complete | get stdout | lines | where $it != ""
    if ($missing | is-empty) { return true }
    (upstream-logged $c $log_file $PACMAN_TRANSFER_TIMEOUT_S archlinux pacman -S --noconfirm --needed --asdeps ...$missing) == 0
}

def build-deps-remove [n: record]: nothing -> nothing {
    let baseline = $n.baseline | to-set
    let extra = ^pacman -Qq | lines | where {|name| not (has $baseline $name) }
    if ($extra | is-empty) { return }
    if (do { ^pacman -Rdd --noconfirm ...$extra } | complete).exit_code != 0 {
        log "removing the build dependencies failed, later builds see them"
    }
}

def regex-escape []: string -> string {
    str replace --all --regex '([.+*?()|\[\]{}^$\\])' '\$1'
}

# rel 1 -> 1.<build>; the unsigned package's path
export def repack [c: record, package: path, build: int]: nothing -> string {
    let dir = $c.cache | path join repack
    rm --recursive --force $dir
    mkdir $dir ($c.cache | path join stage)
    ^bsdtar -xpf $package -C $dir
    let pkginfo_file = $dir | path join .PKGINFO
    let pkginfo = open --raw $pkginfo_file
    let name = pkginfo-get $pkginfo pkgname | get -o 0 | default ""
    let full = pkginfo-get $pkginfo pkgver | get -o 0 | default ""
    let arch = pkginfo-get $pkginfo arch | get -o 0 | default ""
    if $name == "" or $full == "" or $arch == "" { error make {msg: $"($package) has no name, version or arch"} }
    let release = $full | split row "-" | last
    let version = $full | str replace --regex '-[^-]*$' ''
    let new = $"($version)-($release | split row '.' | first).($build)"
    let old = $"($version)-($release)" | regex-escape
    # a pin on a sibling of this base (python-frida needs frida=17.18.0-2) must follow the new release
    let pin = $"^\(\(depend|optdepend|provides|conflicts\) = [^=<>]+[=<>]+\)($old)\(:|$\)"
    for file in [$pkginfo_file ($dir | path join .BUILDINFO)] {
        if not ($file | path exists) { error make {msg: $"($package) has no ($file | path basename)"} }
        let rewritten = open --raw $file | lines | each {|line|
            let line = $line | str replace --regex '^pkgver = .*' $"pkgver = ($new)"
            if $file == $pkginfo_file { $line | str replace --regex $pin $"${1}($new)${3}" } else { $line }
        }
        let rewritten = if $file == $pkginfo_file { $rewritten | append $"replaces = ($OLD_PREFIX)($name)" } else { $rewritten }
        $rewritten | str join "\n" | $"($in)\n" | save --force $file
    }
    let out = $c.cache | path join stage $"($name)-($new)-($arch).pkg.tar.zst"
    let mtree = $c.cache | path join repack.mtree
    # makepkg's create_package: its mtree options, every path sorted, the mtree written outside the tree it lists
    do {
        cd $dir
        let paths = ^find . -mindepth 1 -printf "%P\\0" | split row (char nul) | where $it != "" | sort
        $paths | where $it != ".MTREE" | each { $"($in)(char nul)" } | str join
        | ^bsdtar -cnf - --format=mtree "--options=!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link" --null --files-from -
        | ^gzip -c -f -n | save --force --raw $mtree
        mv --force $mtree .MTREE
        $paths | append .MTREE | uniq | sort | each { $"($in)(char nul)" } | str join | ^bsdtar --no-fflags -cnf - --null --files-from -
        | ^zstd -c -T0 -q | save --force --raw $out
    }
    $out
}

# files go to the outbox; the staging db and this container's pacman see them right away
export def stage-add [c: record, n: record, files: list<string>]: nothing -> any {
    let staged = $files | each {|file|
        put $file $c.outbox_pool
        $c.outbox_pool | path join ($file | path basename)
    }
    if (command-status repo-add -q $c.stage_db ...$staged) != 0 { return null }
    db-sync-local $c $n
}

# a recipe that would end past the budget waits for the next night, its base keeping its last build like a failed one
export def recipe-time-left [c: record]: nothing -> bool {
    (now-s) + $c.recipe_bound_s <= $c.build_deadline
}

# a recipe's validpgpkeys into the builder's keyring; only the bases with keys need the keyserver, so its outage defers
# them and the rest of the night publishes; a key it lacks is makepkg's failure to report
export def keys-fetch [c: record, n: record, base: string, dir: path, log_file: path]: nothing -> record {
    let keys = srcinfo-get ($dir | path join .SRCINFO) validpgpkeys
    if ($keys | is-empty) { return {n: $n, ok: true} }
    let status = with-env {UPSTREAM_TIMEOUT_S: ($KEY_FETCH_TIMEOUT_S | into string)} {
        command-logged $log_file bash $c.upstream keyserver ...$c.as_builder gpg --keyserver $KEYSERVER --recv-keys ...$keys
    }
    if $status == $UNAVAILABLE { return {n: (fail $n $base "deferred to the next night, keyserver unavailable"), ok: false} }
    if $status != 0 { log $"($base): fetching its validpgpkeys failed" }
    {n: $n, ok: true}
}

# a held back or killed night leaves its signed packages in the pool, unpublished; the same recipe stages them again
export def restage [c: record, n: record, base: string, key: string]: nothing -> any {
    let state = $c.cache | path join state
    if $key != (state-get $state $base key) { return null }
    let files = state-words $state $base files | each {|file| $c.repo_dir | path join $file }
    if ($files | is-empty) or not ($files | all {|f| ($f | path exists) and ($"($f).sig" | path exists) }) { return null }
    if (command-status repo-add -q $c.stage_db ...$files) != 0 { return null }
    db-sync-local $c $n
}

def --wrapped makepkg-run [c: record, dir: path, log_file: path, timeout: list<string>, ...args: string]: nothing -> int {
    do {
        cd $dir
        command-logged $log_file timeout ...$timeout ...$c.as_builder ...$args
    }
}

def build-base [c: record, n: record, base: string]: nothing -> record {
    let dir = $c.cache | path join recipes $base
    let log_file = $c.public_logs | path join $"($base).log"
    let out = $c.cache | path join out $base
    let src = $c.cache | path join src $base
    let state = $c.cache | path join state
    "" | save --force $log_file
    # per base: recipes name different tarballs alike (tree-sitter-json-0.24.8.tar.gz from github and pypi)
    ^install -d -o $BUILDER $src
    # pkgver() writes upstream's head into the PKGBUILD, which moves the key
    if (is-vcs $dir) {
        let checked = makepkg-run $c $dir $log_file [-k $FETCH_KILL_AFTER $"($FETCH_TIMEOUT_S)s"] $"SRCDEST=($src)" makepkg -od --noprepare --skipinteg --noconfirm
        if $checked != 0 { log $"($base): upstream version check failed, building from the recipe as is" }
    }
    let key = try { recipe-key $dir } catch { return (fail $n $base "hashing the recipe failed") }
    if (is-current $c $n $base $key) { return $n }
    # restaged, the staging db holds the pool's files whether or not they still resolve
    let restaged = restage $c $n $base $key
    let n = $restaged | default $n
    if $restaged != null and (is-current $c $n $base $key) {
        log $"($base): staged again from an unpublished run"
        return $n
    }
    if not (recipe-time-left $c) { return (fail $n $base "deferred to the next night, the night's build time is spent") }
    let previous = state-get $state $base build
    let build = (if $previous == "" { 0 } else { $previous | into int }) + 1
    log $"($base): building \(build ($build)\)"
    let keys = keys-fetch $c $n $base $dir $log_file
    if not $keys.ok { return $keys.n }
    let n = $keys.n
    rm --recursive --force $out
    ^install -d -o $BUILDER $out
    if not (build-deps-install $c $dir $log_file) {
        build-deps-remove $n
        return (fail $n $base $"installing the build dependencies failed, ($LOGS_NAME)/($base).log")
    }
    let built = makepkg-run $c $dir $log_file [-k $"($BUILD_KILL_AFTER_S)s" $"($BUILD_TIMEOUT_S)s"] $"SRCDEST=($src)" $"PKGDEST=($out)" makepkg -fc --noconfirm --nocheck
    build-deps-remove $n
    if $built != 0 { return (fail $n $base $"build failed, ($LOGS_NAME)/($base).log") }
    let stale = glob ($c.cache | path join stage *)
    if ($stale | is-not-empty) { rm --recursive --force ...$stale }
    let packages = glob ($out | path join *.pkg.tar.zst) | sort
    if ($packages | is-empty) { return (fail $n $base "build produced no package") }
    let repacked = try {
        $packages | each {|package|
            {file: (repack $c $package $build), name: (pkginfo-get (^bsdtar -xOf $package .PKGINFO) pkgname | first)}
        }
    } catch { return (fail $n $base "repack failed") }
    let staged = stage-add $c $n $repacked.file
    if $staged == null { return (fail $n $base "repo-add failed") }
    state-set $state $base $key $build $repacked.name ($repacked.file | each { path basename })
    rm --recursive --force $out
    log $"($base): staged ($repacked.name | str join ' ')"
    $staged | upsert built ($staged.built | append $base)
}

# -----------------------------------------------------------------------------
# BUILD: SNAPSHOT
# -----------------------------------------------------------------------------

# names the staged set is checked and installed by: listed official ones plus everything built. A local recipe's names
# come as lsck0/<name>: it may replace an official package, which pacman's repo order would otherwise resolve them to
export def snapshot-targets [c: record, n: record]: nothing -> list<string> {
    let state = $c.cache | path join state
    $n.official_wanted | append ($n.bases | each {|base|
        let prefix = if ($n.kind | get $base) == local { $"($REPO)/" } else { "" }
        state-words $state $base names | where {|name| has $n.db_file $name } | each { $"($prefix)($in)" }
    } | flatten) | sort | uniq
}

# a failed base keeps its last build staged, unless that no longer resolves and would hold back the night
def drop-unresolvable [c: record, n: record]: nothing -> record {
    let state = $c.cache | path join state
    mut n = $n
    for base in $n.bases {
        if not (has $n.failed $base) { continue }
        let staged = state-words $state $base names | where {|name| has $n.db_file $name }
        if ($staged | is-empty) or (names-resolve $c $staged) { continue }
        log $"($base): dropping ($staged | str join ' '), the last build no longer resolves"
        if (command-status repo-remove -q $c.stage_db ...$staged) != 0 { continue }
        $n = db-sync-local $c $n | upsert dropped ($n.dropped | append $base)
    }
    $n
}

def closure-read [file: path]: nothing -> list<record> {
    open --raw $file | lines | where $it != "" | split column " " repo name file
}

# the official closure of the whole set at today's versions, into the outbox and staged
export def snapshot-official [c: record, n: record]: nothing -> record {
    let root = $c.cache | path join resolve
    let closure = $c.cache | path join closure.txt
    let snapshot_log = $c.public_logs | path join snapshot.log
    let targets = snapshot-targets $c $n
    # an empty local db, so the closure includes what the build container has installed
    dbpath-create $root
    let dbs = glob ($c.pacman_sync | path join *.db)
    if ($dbs | is-empty) or (command-status cp ...$dbs ($root | path join sync)) != 0 {
        return ($n | upsert held_back "copying the sync dbs failed")
    }
    # publish downloads and checks the official files against the dbs this closure came from
    for repo in $OFFICIAL_REPOS {
        if (command-status cp ($c.pacman_sync | path join $"($repo).db") $c.outbox_sync) != 0 {
            return ($n | upsert held_back $"copying the ($repo) db failed")
        }
    }
    let resolved = do {
        ^pacman --config $c.pacman_conf --dbpath $root -Sp --noconfirm --print-format "%r %n %f" ...$targets
    } | complete
    $resolved.stderr | save --force $snapshot_log
    if $resolved.exit_code != 0 {
        return ($n | upsert held_back $"the set does not resolve against today's repos, ($LOGS_NAME)/snapshot.log")
    }
    $resolved.stdout | save --force $closure
    let official = closure-read $closure | where repo != $REPO
    let new = $official | where {|row| ($n.db_file | get -o $row.name) != $row.file }
    log $"snapshot: ($official | length) official packages, ($new | length) new"
    let n = $n | upsert official_names $official.name
    if ($new | is-empty) { return $n }
    # downloads land in the outbox; a file the pacman cache or the pool holds already is used in place; a first run
    # has no pool yet, and this container cannot create it
    let cachedirs = [$c.outbox_pool ($c.cache | path join pacman)] | append (if ($c.repo_dir | path exists) { [$c.repo_dir] } else { [] })
    | each { [--cachedir $in] } | flatten
    let downloaded = upstream-logged $c $snapshot_log $PACMAN_TRANSFER_TIMEOUT_S archlinux pacman --config $c.pacman_conf --dbpath $root -Swdd --noconfirm ...$cachedirs ...($new | each { $"($in.repo)/($in.name)" })
    if $downloaded != 0 {
        return ($n | upsert held_back $"downloading the official packages failed, ($LOGS_NAME)/snapshot.log")
    }
    mut paths = []
    for row in $new {
        let served = $c.repo_dir | path join $row.file
        if ($served | path exists) {
            $paths = $paths | append $served
            continue
        }
        let pooled = $c.outbox_pool | path join $row.file
        if not ($pooled | path exists) {
            let cached = $c.cache | path join pacman $row.file
            if not ($cached | path exists) { return ($n | upsert held_back $"($row.file) is in no cache after the download") }
            put $cached $c.outbox_pool
        }
        $paths = $paths | append $pooled
    }
    if (command-status repo-add -q $c.stage_db ...$paths) != 0 {
        return ($n | upsert held_back "repo-add of the official packages failed")
    }
    db-sync-local $c $n
}

# staging only: drops what neither a base in the closure nor the snapshot still needs
def db-prune [c: record, n: record]: nothing -> record {
    if not $n.resolve_complete {
        log "prune skipped, resolution incomplete"
        return $n
    }
    let state = $c.cache | path join state
    # lsck0 lines too: an official package arch dropped resolves from the staged copy alone
    let keep = $n.bases | each {|base| state-words $state $base names } | flatten
    | append (closure-read ($c.cache | path join closure.txt) | get name) | to-set
    let stale = $n.db_file | columns | where {|name| not (has $keep $name) }
    mut n = $n
    if ($stale | is-not-empty) {
        log $"removing ($stale | str join ' ')"
        if (command-status repo-remove -q $c.stage_db ...$stale) == 0 { $n = db-sync-local $c $n }
    }
    let in_closure = $n.bases | to-set
    for file in (ls $state | get name) {
        if not (has $in_closure ($file | path basename)) { rm --force $file }
    }
    $n
}

# -----------------------------------------------------------------------------
# BUILD: OUTBOX
# -----------------------------------------------------------------------------

# the running build on the builder's status page; the served status.json is publish's
def progress-write [c: record, n: record, phase: string, current: string = "", done: int = 0]: nothing -> nothing {
    let served = $c.served | path join status.json
    let previous = if ($served | path exists) { open --raw $served | from json } else { {} }
    let failures = failures-list $n.failed
    let status = $previous | merge {running: {
        started: (time-format $c.run_started $TIME_FORMAT), updated: (date now | date to-timezone UTC | format date $TIME_FORMAT)
        commit: $c.commit, phase: $phase, current: (if $current == "" { null } else { $current }), done: $done
        total: ($n.order | length), built: ($n.built | length), failing: ($failures | length), failed: $failures
    }}
    let file = $c.cache | path join status.json
    $status | to json --indent 2 | save --force $file
    put $file $c.public
}

# the proposal: staged db, working state and report; the run id last, it marks the outbox complete
def outbox-write [c: record, n: record]: nothing -> nothing {
    ^cp $c.stage_db $c.outbox_db
    ^cp -a ($c.cache | path join state) $c.outbox_state
    {
        held_back: (if $n.held_back == "" { null } else { $n.held_back })
        official: ($n.official_names | length)
        built: $n.built
        dropped: $n.dropped
        targets: (snapshot-targets $c $n)
        failed: (failures-list $n.failed)
    } | to json --indent 2 | save --force $c.outbox_report
    $c.run_started | into string | save --force $c.outbox_run
}

def caches-clean [c: record]: nothing -> nothing {
    let cache = $c.cache
    ^find ($cache | path join pacman) ($cache | path join src) -maxdepth 2 -type f -mtime $"+($CACHE_KEEP_DAYS)" -delete
    # go trims its build cache only while some go build runs; go/mod and cargo/ are fetched sources, kept
    let go_build = $cache | path join go build
    if ($go_build | path exists) { ^find $go_build -type f -mtime $"+($BUILD_CACHE_KEEP_DAYS)" -delete }
}

# -----------------------------------------------------------------------------
# PUBLISH: SETUP
# -----------------------------------------------------------------------------

def key-setup [c: record]: nothing -> record {
    do { ^gpg --batch --import $c.signing_key_file } | complete | ignore
    let key = ^gpg --with-colons --list-secret-keys | lines | each { split row ":" } | where { $in.0 == fpr } | get -o 0.9
    if $key == null { die $"no signing key in ($c.signing_key_file)" }
    $c | upsert key $key
}

# official repos only: nothing the builder produced is ever installed here
def publish-pacman-setup [c: record, p: record]: nothing -> record {
    let installed = upstream-quiet $c $PACMAN_TRANSFER_TIMEOUT_S archlinux pacman -S --noconfirm --needed rsync openssh
    if $installed != 0 { die "installing the push tools failed" }
    let official = ^pacman -Slq ...$OFFICIAL_REPOS | lines | where $it != "" | uniq
    if ($official | is-empty) { die "no official package names" }
    $p | upsert official_name ($official | to-set)
}

# the outbox of this run, complete, with no link where publish reads
def outbox-check [c: record]: nothing -> nothing {
    for dir in [$c.outbox $c.outbox_pool $c.outbox_sync $c.outbox_state] {
        if ($dir | path type) != dir { die $"($dir) is not a directory" }
    }
    if not (outbox-file-check $c.outbox_run) or (open --raw $c.outbox_run | str trim) != ($c.run_started | into string) {
        die $"the outbox is not from this run \(($c.run_started)\), the build did not finish"
    }
    if not (outbox-file-check $c.outbox_db) or not (outbox-file-check $c.outbox_report) { die "the outbox has no db or report" }
}

# served from the served db, state_file and owner_of from the signed state
def served-load [c: record, p: record]: nothing -> record {
    let db = $c.repo_dir | path join $"($REPO).db.tar.gz"
    let served = if ($db | path exists) { db-index $db } else { {} }
    let bases = ls $c.served_state | get name | each { path basename }
    let owner_of = $bases | each {|base| state-words $c.served_state $base names | each {|name| {key: $name, value: $base} } }
    | flatten | to-map
    let state_file = $bases | each {|base| state-words $c.served_state $base files } | flatten
    | each {|file| {key: $file, value: (file-package-name $file)} } | to-map
    $p | merge {served: $served, owner_of: $owner_of, state_file: $state_file}
}

# -----------------------------------------------------------------------------
# PUBLISH: ACCEPT
# -----------------------------------------------------------------------------

def base-reject [p: record, base: string, reason: string]: nothing -> record {
    fail $p $base $"rejected: ($reason)"
}

# the reason a proposed base may not publish, "" when it may; its files are copied into <dir> as they are checked
export def base-check [c: record, p: record, base: string, dir: path]: nothing -> string {
    if not (outbox-file-check ($c.outbox_state | path join $base)) { return "no state in the outbox" }
    let is_local = local-recipe-exists $c $base
    let key = state-get $c.outbox_state $base key
    let build = state-get $c.outbox_state $base build
    let names = state-words $c.outbox_state $base names
    let files = state-words $c.outbox_state $base files
    let previous = state-get $c.served_state $base build | if $in == "" { "0" } else { $in }
    if $key !~ $KEY_PATTERN { return $"recipe key '($key)'" }
    # a reused build number would reuse a file name a client may have cached with other contents
    if $build !~ '^[0-9]+$' or ($build | into int) <= ($previous | into int) {
        return $"build ($build) does not follow ($previous)"
    }
    if ($names | is-empty) or ($files | is-empty) { return "no names or files" }
    for name in $names {
        if $name !~ $NAME_PATTERN { return $"package name '($name)'" }
        let owner = $p.owner_of | get -o $name
        if $owner != null and $owner != $base { return $"($name) belongs to ($owner)" }
        if not $is_local and (has $p.official_name $name) { return $"($name) is an official package" }
    }
    mut open_names = $names
    for file in $files {
        if $file !~ $FILE_PATTERN { return $"file name '($file)'" }
        # a file in the pool that nothing signed references is a killed publish's, never seen by a client
        let pooled = $c.repo_dir | path join $file
        if ($pooled | path exists) and ((has $p.state_file $file) or ($p.served | get -o (file-package-name $file)) == $file) {
            return $"($file) exists in the pool already"
        }
        let proposed = $c.outbox_pool | path join $file
        if not (outbox-file-check $proposed) { return $"($file) is not in the outbox" }
        # checked and signed as a copy of its own: what was checked is what gets signed
        let path = $dir | path join $file
        ^cp $proposed $path
        let pkginfo = do { ^bsdtar -xOf $path .PKGINFO } | complete
        if $pkginfo.exit_code != 0 { return $"($file) has no readable .PKGINFO" }
        let package = pkginfo-get $pkginfo.stdout pkgname | get -o 0 | default ""
        let version = pkginfo-get $pkginfo.stdout pkgver | get -o 0 | default ""
        let arch = pkginfo-get $pkginfo.stdout arch | get -o 0 | default ""
        if $file != $"($package)-($version)-($arch).pkg.tar.zst" { return $"($file) is ($package)-($version)-($arch) inside" }
        if $package not-in $open_names { return $"($file) is ($package), which is not an open name of ($names | str join ' ')" }
        $open_names = $open_names | where $it != $package
        # replaces makes a pacman -Syu swap the replaced package out on every machine, listed there or not
        for replaced in (pkginfo-get $pkginfo.stdout replaces | each { version-strip }) {
            if not $is_local and (has $p.official_name $replaced) { return $"($file) replaces the official ($replaced)" }
        }
    }
    if ($open_names | is-not-empty) { return $"no file for ($open_names | first)" }
    ""
}

# one rebuilt base of the proposal, signed into the pool only when it may publish what it built; a rejection keeps
# its served build, only an unexpected error stops the publish
def base-accept [c: record, p: record, base: string]: nothing -> record {
    if $base !~ $NAME_PATTERN { return (base-reject $p $base "not a package base name") }
    let dir = $c.work | path join accept
    rm --recursive --force $dir
    mkdir $dir
    let reason = base-check $c $p $base $dir
    if $reason != "" { return (base-reject $p $base $reason) }
    let names = state-words $c.outbox_state $base names
    let files = state-words $c.outbox_state $base files
    # files first, state last: a killed publish leaves files nothing references, which the next one may overwrite
    for file in $files {
        let path = $dir | path join $file
        sign $c $path
        put $"($path).sig" $c.repo_dir
        put $path $c.repo_dir
    }
    state-set $c.served_state $base (state-get $c.outbox_state $base key) (state-get $c.outbox_state $base build | into int) $names $files
    rm --recursive --force $dir
    log $"($base): signed ($files | str join ' ')"
    $p | merge {
        owner_of: ($p.owner_of | merge ($names | each {|name| {key: $name, value: $base} } | to-map))
        state_file: ($p.state_file | merge ($files | each {|file| {key: $file, value: (file-package-name $file)} } | to-map))
        built: ($p.built | append $base)
    }
}

# bases the builder pruned leave the signed state once the published db names none of their files
def state-prune [c: record, p: record]: nothing -> nothing {
    for path in (ls $c.served_state | get name) {
        let base = $path | path basename
        if ($c.outbox_state | path join $base | path exists) { continue }
        let served = state-words $c.served_state $base files | any {|file| ($p.final | get -o (file-package-name $file)) == $file }
        if not $served { rm --force $path }
    }
}

# -----------------------------------------------------------------------------
# PUBLISH: ASSEMBLE
# -----------------------------------------------------------------------------

# final from the proposed names. Each one's file must be a signed build of it or the file served for it already; a
# base's name that is neither keeps its served file; any other name is official and maps to the file arch's dbs name
# for it, which pacman checks against arch's keyring on the way into the pool
export def assemble [c: record, p: record]: nothing -> record {
    let proposed = try { db-index $c.outbox_db } catch { return ($p | upsert held_back "the proposed db cannot be read") }
    let proposed_owner = ls $c.outbox_state | get name | each { path basename }
    | where {|base| $base =~ $NAME_PATTERN and (outbox-file-check ($c.outbox_state | path join $base)) }
    | each {|base| state-words $c.outbox_state $base names | each {|name| {key: $name, value: $base} } } | flatten | to-map
    mut final = []
    mut pending = []
    for row in ($proposed | transpose name file) {
        let served = $p.served | get -o $row.name
        if ($p.state_file | get -o $row.file) == $row.name or $served == $row.file {
            $final = $final | append {key: $row.name, value: $row.file}
        } else if (has $p.owner_of $row.name) or (has $proposed_owner $row.name) {
            if $served != null {
                log $"($row.name): ($row.file) is not signed, keeping ($served)"
                $final = $final | append {key: $row.name, value: $served}
            } else {
                log $"($row.name): ($row.file) is not signed, left out"
            }
        } else {
            $pending = $pending | append $row.name
        }
    }
    let p = $p | upsert final ($final | to-map)
    log $"assemble: ($proposed | columns | length) names proposed, ($pending | length) official files new"
    if ($pending | is-empty) { return $p }
    let root = $c.work | path join official
    dbpath-create $root
    for repo in $OFFICIAL_REPOS {
        let db = $c.outbox_sync | path join $"($repo).db"
        if not (outbox-file-check $db) { return ($p | upsert held_back $"the outbox has no ($repo) db") }
        ^cp $db ($root | path join sync)
    }
    let pending = $pending
    let resolved = do { ^pacman --config $c.pacman_conf --dbpath $root -Spdd --noconfirm --print-format "%r %n %f" ...$pending } | complete
    if $resolved.exit_code != 0 {
        let list = $pending | str join " " | str substring 0..<$HELD_BACK_QUOTE_MAX
        return ($p | upsert held_back $"proposed names that are neither built nor official: ($list)")
    }
    let official = $resolved.stdout | lines | where $it != "" | split column " " repo name file
    for row in $official {
        let wanted = $proposed | get -o $row.name
        if $wanted != $row.file {
            return ($p | upsert held_back $"($row.name): proposed ($wanted | default 'nothing'), ($row.repo) has ($row.file)")
        }
    }
    let p = $p | upsert final ($p.final | merge ($official | each {|row| {key: $row.name, value: $row.file} } | to-map))
    # pacman checks every file against its db entry and arch's keyring, the pool's and the outbox's copies included,
    # and fetches what neither holds; a .sig next to a file says nothing, pacman may have put arch's there
    let download_log = $c.work | path join download.log
    let downloaded = upstream-logged $c $download_log $PACMAN_TRANSFER_TIMEOUT_S archlinux pacman --config $c.pacman_conf --dbpath $root -Swdd --noconfirm --cachedir $c.repo_dir --cachedir $c.outbox_pool ...($official | each { $"($in.repo)/($in.name)" })
    if $downloaded != 0 {
        print (open --raw $download_log)
        return ($p | upsert held_back "downloading or checking the official packages failed")
    }
    for row in $official {
        let pooled = $c.repo_dir | path join $row.file
        if not ($pooled | path exists) {
            let proposed_file = $c.outbox_pool | path join $row.file
            if not (outbox-file-check $proposed_file) { return ($p | upsert held_back $"($row.file) is in no cache after the download") }
            put $proposed_file $c.repo_dir
        }
        sign $c $pooled
    }
    $p
}

# the served db plus what changed, every added file carrying a signature of the repo key
export def db-assemble [c: record, p: record]: nothing -> record {
    let db_dir = $c.work | path join db
    let db = $db_dir | path join $"($REPO).db.tar.gz"
    db-copy-served $c $db_dir
    let index = db-index $db
    let remove = $index | columns | where {|name| not (has $p.final $name) }
    let add = $p.final | transpose name file | where {|row| ($index | get -o $row.name) != $row.file }
    for row in $add {
        let file = $c.repo_dir | path join $row.file
        if (do { ^gpg --batch --verify $"($file).sig" $file } | complete).exit_code != 0 {
            return ($p | upsert held_back $"($row.file) has no valid signature")
        }
    }
    log $"db: ($add | length) added, ($remove | length) removed"
    if ($remove | is-not-empty) { ^repo-remove -q $db ...$remove }
    if ($add | is-not-empty) { ^repo-add -q $db ...($add | each {|row| $c.repo_dir | path join $row.file }) }
    $p
}

# what a client with [lsck0] above everything sees: the listed and built names resolve from it alone
def snapshot-verify [c: record, p: record]: nothing -> record {
    let targets = open --raw $c.outbox_report | from json | get targets
    if ($targets | is-empty) { return ($p | upsert held_back "the proposal names no targets") }
    let root = $c.work | path join verify
    dbpath-create $root
    ^cp ($c.work | path join db $"($REPO).db.tar.gz") ($root | path join sync $"($REPO).db")
    let conf = $root | path join pacman.conf
    $"[options]\nArchitecture = auto\nSigLevel = Never\n\n[($REPO)]\nServer = file://($c.repo_dir)\n" | save --force $conf
    let verified = do { ^pacman --config $conf --dbpath $root -Sp --noconfirm ...$targets } | complete
    if $verified.exit_code == 0 { return $p }
    print $verified.stderr
    $p | upsert held_back $"the set does not resolve from ($REPO) alone"
}

# whole days since the served snapshot was published, null without one
export def served-age-days [c: record]: nothing -> any {
    if ($c.snapshot_current | path type) != symlink { return null }
    let served = ^readlink $c.snapshot_current | str trim
    if $served !~ $SNAPSHOT_PATTERN { return null }
    let published = try { $"($served)T00:00:00Z" | into datetime | into int } catch { return null }
    ($c.run_started - $published // $NANOSECONDS_PER_SECOND) // $SECONDS_PER_DAY
}

# no listed name the served db provides may go missing, within the hold (header, Completeness)
export def completeness-check [c: record, p: record, proposed_missing: list<string>]: nothing -> record {
    let p = $p | upsert proposed_missing $proposed_missing
    let lost = $proposed_missing | where $it not-in $p.snapshot_missing
    if ($lost | is-empty) { return $p }
    let list = $lost | str join " " | str substring 0..<$HELD_BACK_QUOTE_MAX
    let age = served-age-days $c
    if $age != null and $age >= $COMPLETENESS_HOLD_DAYS {
        log $"publishing without names held back for ($age) days: ($list)"
        return $p
    }
    $p | upsert held_back $"listed names the served snapshot has and this one lacks: ($list)"
}

# -----------------------------------------------------------------------------
# PUBLISH: PUBLISH
# -----------------------------------------------------------------------------

# db, signature and pacman's names for both into a directory, copied or hardlinked
def db-put [from: path, dir: path, --link]: nothing -> nothing {
    for f in $DB_FILES {
        for file in [$"($from)/($f).sig" $"($from)/($f)"] {
            if $link { link-into $file $dir } else { put $file $dir }
        }
    }
    for f in [db files] {
        symlink-set $"($REPO).($f).tar.gz" ($dir | path join $"($REPO).($f)")
        symlink-set $"($REPO).($f).tar.gz.sig" ($dir | path join $"($REPO).($f).sig")
    }
}

# the pool's file and its signature hardlinked into dir, unless it holds them already (the pool does)
def pool-link [c: record, file: string, dir: path]: nothing -> nothing {
    for name in [$file $"($file).sig"] {
        if not ($dir | path join $name | path exists) { ^ln ($c.repo_dir | path join $name) ($dir | path join $name) }
    }
}

# <root>/<date>/x86_64 hardlinks the files and gets the db, current moves to it only once it is whole, then
# <root>/x86_64, what every client without a pin reads, gets them too; a second publish the same day updates that
# day's snapshot in place. The full tree's x86_64/ is the pool itself
def tree-publish [c: record, root: path, db: path, files: list<string>]: nothing -> nothing {
    let snapshot = time-format $c.run_started $DATE_FORMAT
    let dir = $root | path join $snapshot $ARCH
    let latest = $root | path join $ARCH
    let manifest = $db | path join $SNAPSHOT_MANIFEST
    mkdir $dir $latest
    for file in $files { pool-link $c $file $dir }
    db-put $db $dir
    {
        date: $snapshot, started: (time-format $c.run_started $TIME_FORMAT)
        published: (date now | date to-timezone UTC | format date $TIME_FORMAT), source: $c.source, ref: $c.ref
        commit: $c.commit, signing_key: $c.key, packages: ($files | length)
    } | to json --indent 2 | save --force $manifest
    sign $c $manifest
    put $"($manifest).sig" ($root | path join $snapshot)
    put $manifest ($root | path join $snapshot)
    symlink-set $snapshot ($root | path join $CURRENT_NAME)
    let keep = $files | to-set
    for file in (glob ($dir | path join *.pkg.tar.zst)) {
        if not (has $keep ($file | path basename)) { rm --force $file $"($file).sig" }
    }
    for file in $files { pool-link $c $file $latest }
    db-put $dir $latest --link
}

# the internet's db: the night's without the official names; a local recipe's build over an official name is the
# owner's own and stays, every other official name is served by arch's mirrors
export def internet-assemble [c: record, p: record]: nothing -> record {
    let dir = $c.work | path join internet
    rm --recursive --force $dir
    mkdir $dir
    for f in $DB_FILES { ^cp ($c.work | path join db $f) ($dir | path join $f) }
    let rows = $p.final | transpose name file
    let own = $rows | where {|row| ($p.state_file | get -o $row.file) == $row.name }
    let official = $rows | where {|row| ($p.state_file | get -o $row.file) != $row.name }
    log $"internet: ($own | length) own builds of ($rows | length) packages"
    if ($official | is-not-empty) { ^repo-remove -q ($dir | path join $"($REPO).db.tar.gz") ...$official.name }
    $p | upsert internet_files $own.file
}

export def db-publish [c: record, p: record]: nothing -> nothing {
    for dir in [($c.work | path join db) ($c.work | path join internet)] {
        for f in $DB_FILES { sign $c ($dir | path join $f) }
    }
    tree-publish $c $c.served ($c.work | path join db) ($p.final | values)
    tree-publish $c $c.internet_served ($c.work | path join internet) $p.internet_files
}

# superseded, removed and held back package files leave dir once its db no longer references them; the dated
# snapshots keep their hardlinks
export def files-prune [dir: path, files: list<string>]: nothing -> nothing {
    let referenced = $files | to-set
    for file in (glob ($dir | path join *.pkg.tar.zst)) {
        if not (has $referenced ($file | path basename)) { rm --force $file $"($file).sig" }
    }
}

# <root> keeps three dated snapshots: the newest, the first of this month and the first of this week (from Monday),
# plus whichever one current names
export def snapshot-prune [c: record, root: path]: nothing -> nothing {
    let today = time-format $c.run_started $DATE_FORMAT
    let weekday = time-format $c.run_started "%u" | into int
    let week_start = time-format ($c.run_started - ($weekday - 1) * $SECONDS_PER_DAY) $DATE_FORMAT
    let month_start = ($today | str substring 0..6) + "-01"
    let current = ^readlink ($root | path join $CURRENT_NAME) | str trim
    let dated = ls $root | where type == dir | get name | where { ($in | path basename) =~ $SNAPSHOT_PATTERN } | sort
    let names = $dated | each { path basename }
    let first_since = {|start| $names | where $it >= $start | get 0? }
    let keep = [($names | reverse | get 0?) (do $first_since $month_start) (do $first_since $week_start) $current] | compact
    for dir in $dated {
        let name = $dir | path basename
        if $name in $keep { continue }
        log $"removing snapshot ($name)"
        rm --recursive --force $dir
    }
}

# -----------------------------------------------------------------------------
# PUBLISH: STATUS
# -----------------------------------------------------------------------------

def status-write [c: record, p: record]: nothing -> nothing {
    let now = date now | date to-timezone UTC | format date $TIME_FORMAT
    let held = $p.held_back != ""
    let packages = if $held { $p.served | columns | length } else { $p.final | columns | length }
    let snapshot = if $held { null } else { time-format $c.run_started $DATE_FORMAT }
    let report = open --raw $c.outbox_report | from json
    let failures = $report.failed | append (failures-list $p.failed) | where $it != "" | sort | uniq
    let missing = $p.snapshot_missing
    let indented = {|items| $items | each { $"  ($in)" } }
    let text = [
        $"last build: ($now)"
        $"source:     ($c.source) ($c.ref) ($c.commit)"
        $"snapshot:   ($snapshot | default 'none, held back')"
        $"packages:   ($packages)"
        $"official:   ($report.official)"
        $"published:  (if $held { $'no, held back: ($p.held_back)' } else { 'yes' })"
        $"built:      (if ($p.built | is-empty) { 'none' } else { $p.built | str join ' ' })"
        $"dropped:    (if ($report.dropped | is-empty) { 'none' } else { $report.dropped | str join ' ' })"
        $"failed:     ($failures | length)"
    ] | append (do $indented $failures) | append $"missing:    ($missing | length) listed, not in the served snapshot"
    | append (do $indented $missing)
    let status_txt = $c.work | path join status.txt
    let status_json = $c.work | path join status.json
    $text | str join "\n" | $"($in)\n" | save --force $status_txt
    {
        packages: $packages, failing: ($failures | length), last_build: $now, commit: $c.commit, snapshot: $snapshot
        held_back: (if $held { $p.held_back } else { null }), failed: $failures, dropped: $report.dropped
        missing: $missing, running: null
    } | to json --indent 2 | save --force $status_json
    put $status_json $c.served
    put $status_txt $c.served
    # archbuild-if-stale ages the run from its start, a long night must not skip the next one
    ^touch -d $"@($c.run_started)" ($c.served | path join status.txt)
    print (open --raw $status_txt)
}

# -H: the dated snapshots are hardlinks of the pool there too; pacman -Sw --cachedir leaves download-* dirs
def --wrapped push-rsync [c: record, ...args: string]: nothing -> bool {
    let ssh = [ssh -i $c.push_key_file -o StrictHostKeyChecking=yes -o $"UserKnownHostsFile=($c.push_known_hosts_file)"
        -o $"ConnectTimeout=($PUSH_CONNECT_TIMEOUT_S)"] | str join " "
    (command-status rsync -aH --exclude "download-*" --exclude "/.state/" -e $ssh ...$args) == 0
}

# the build container wrote them: regular *.log files only, never a link, which here could reach the keys
export def logs-push [c: record]: nothing -> bool {
    let only_logs = [--no-links --no-devices --no-specials $"--max-size=($c.log_push_size_max)"]
    if ($c.public_logs | path type) != dir {
        log $"($c.public_logs) is not a directory, the base logs stay on vm-112"
    } else if not (push-rsync $c ...$only_logs --delete --exclude "*/" --include "*.log" --exclude "*" $"($c.public_logs)/" $"($c.push_target)/($LOGS_NAME)/") {
        return false
    }
    push-rsync $c ...$only_logs $c.build_log $"($c.push_target)/"
}

# mirror to the always-on dmz host: packages and snapshot dirs, then the dbs and current, then the logs the status
# names, then the status, then deletions; a failure fails the unit, the mirror keeps its last whole copy
export def push [c: record]: nothing -> bool {
    if $c.push_target == "" or not ($c.push_key_file | path exists) { return true }
    if not ($c.repo_dir | path join $"($REPO).db" | path exists) { return true }
    log $"pushing the repo to ($c.push_target)"
    let served = $"($c.served)/"
    let target = $"($c.push_target)/"
    let pushed = (
        (push-rsync $c --exclude $"($REPO).db*" --exclude $"($REPO).files*" --exclude $"/($CURRENT_NAME)"
            --exclude $"($c.internet_prefix)/($CURRENT_NAME)" --exclude "/status.*" $served $target)
        and (push-rsync $c --delay-updates --exclude "/status.*" $served $target)
        and (logs-push $c)
        and (push-rsync $c ($c.served | path join status.txt) ($c.served | path join status.json) $target)
        and (push-rsync $c --delete --exclude $"/($LOGS_NAME)/" --exclude $"/($BUILD_LOG_NAME)" $served $target)
    )
    if not $pushed { log $"push to ($c.push_target) failed, the dmz mirror keeps its last copy" }
    $pushed
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

def build-main [c: record]: nothing -> nothing {
    log "setting up the build"
    setup-build $c
    db-copy-served $c ($c.cache | path join db)
    mut n = setup-build-pacman $c (night-empty)
    log $"resolving the package list of ($c.dotfiles) at ($c.commit)"
    progress-write $c $n resolving
    $n = repo-has-load $n
    $n = lists-read $c $n
    $n = resolve $c $n
    $n = plan $n
    log $"($n.order | length) bases, ($n.official_wanted | length) official packages listed"
    mut done = 0
    for base in $n.order {
        progress-write $c $n building $base $done
        if not (has $n.failed $base) { $n = build-base $c $n $base }
        $done += 1
    }
    progress-write $c $n proposing "" $done
    $n = drop-unresolvable $c $n
    $n = snapshot-official $c $n
    if $n.held_back == "" { $n = db-prune $c $n }
    if $n.held_back != "" { log $"held back: ($n.held_back)" }
    outbox-write $c $n
    caches-clean $c
    log $"proposed ($n.db_file | columns | length) packages, ($n.built | length) built"
}

def publish-main [c: record]: nothing -> nothing {
    log "setting up the publish"
    # empty, the internet's tree would be the full one, and its prune would take the pool
    if $c.internet_prefix !~ $INTERNET_PREFIX_PATTERN { die $"ARCHBUILD_INTERNET_PREFIX '($c.internet_prefix)' is no path prefix" }
    outbox-check $c
    rm --recursive --force $c.work
    mkdir $c.work $c.repo_dir $c.served_state
    let c = key-setup $c
    mut p = publish-pacman-setup $c (publish-empty)
    $p = served-load $c $p
    # read before anything is signed: a list that cannot be read stops the night here, as it stops the build
    let served_db = $c.repo_dir | path join $"($REPO).db.tar.gz"
    $p = $p | upsert snapshot_missing (try { listed-missing $c $served_db } catch { die "checking the served db against the list failed" })
    let report = open --raw $c.outbox_report | from json
    $p = $p | upsert held_back ($report.held_back | default "")
    for base in $report.built { $p = base-accept $c $p $base }
    if $p.held_back == "" { $p = assemble $c $p }
    if $p.held_back == "" { $p = db-assemble $c $p }
    if $p.held_back == "" { $p = snapshot-verify $c $p }
    if $p.held_back == "" {
        let proposed_db = $c.work | path join db $"($REPO).db.tar.gz"
        let proposed_missing = try { listed-missing $c $proposed_db } catch { die "checking the proposed db against the list failed" }
        $p = completeness-check $c $p $proposed_missing
    }
    if $p.held_back == "" {
        log $"publishing snapshot (time-format $c.run_started $DATE_FORMAT)"
        $p = $p | upsert snapshot_missing $p.proposed_missing
        $p = internet-assemble $c $p
        db-publish $c $p
        files-prune $c.repo_dir ($p.final | values)
        files-prune ($c.internet_served | path join $ARCH) $p.internet_files
        snapshot-prune $c $c.served
        snapshot-prune $c $c.internet_served
        state-prune $c $p
    } else {
        log $"held back: ($p.held_back)"
    }
    status-write $c $p
    if not (push $c) { exit 1 }
}

def main [mode: string]: nothing -> nothing {
    let c = context-default
    if $c.commit == "" { die "ARCHBUILD_COMMIT is unset: the verified arch-dotfiles commit" }
    if $c.run_started == 0 { die "ARCHBUILD_RUN_STARTED is unset: epoch seconds of the run start" }
    if $c.build_budget_s == "" { die "ARCHBUILD_BUILD_BUDGET_S is unset: seconds the recipes of a night may take" }
    match $mode {
        "build" => { build-main $c }
        "publish" => { publish-main $c }
        _ => { die "usage: archrepo-build.nu build|publish" }
    }
}
