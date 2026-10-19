# copy a folder to proton drive with proton's own cli, one way
#
# usage: proton-mirror mirror|upload, the environment as kopia.nix's proton-sync and proton-cold-storage units set it
#   mirror  the kopia repository: upload what is new, prune what vanished
#   upload  cold storage: upload what is new, a changed file as a new revision; nothing remote is ever trashed, so a
#           file deleted here stays off-site. A source without a file is refused; a success touches
#           PROTON_MIRROR_UPLOADED
#
# The source lands at <target>/<basename of source>. In a mirror its files are content-addressed blobs, uploaded as
# they are; a vanished one is trashed by path, then deleted from the trash by its name, which no other trashed item
# shares. The cli (0.8.0) has no mirror mode, so the manifest (paths earlier runs uploaded, or failed to prune) is the
# only memory of what is remote: lose it and the remote keeps what was deleted before. An upload's verdict comes from
# the cli's json summary (-j, the last stdout line), never from the log text, where a warning shaped like an item
# error would flip it. A mirror that would prune more than MAX_GONE_PERCENT of the manifest stops until
# <manifest>.allow-large is touched.

# paths per trash or delete call: the cli lists each path's folder, so a bound keeps a call's runtime and argv small
const BATCH_COUNT = 100
# a list, rename, trash or delete call; the upload is bounded by the unit's timeout alone, it moves the whole repository
const CALL_TIMEOUT_SECONDS = 600
# a run waits this long for a bisync, a verify or the other mode to let go of proton, then counts as failed
const LOCK_WAIT_SECONDS = 7200
const GONE = "Node not found"
const TRASH_GONE = "Trashed node not found"
# upload failures that are expected skips: sockets and symlinks
const SKIPPED_ERROR = "Not a regular file or directory"
# a file changed mid-upload: worth one more try
const CHANGED_ERROR = "IntegrityError"
const UNIQUE_PREFIX = "homelab-offsite-gone-"

# a failure while proton went down is the outage's, any other this run's own
def failed [message: string]: nothing -> nothing {
    let probe = status-of $env.PROTON_MIRROR_PROBE
    if $probe != 0 { exit $probe }
    die $message
}

def --wrapped cli [...args: string]: nothing -> record {
    ^timeout $CALL_TIMEOUT_SECONDS proton-drive filesystem ...$args | complete
}

def all-ok [stdout: string]: nothing -> bool {
    try { $stdout | from json | all {|item| $item.ok? == true } } catch { false }
}

# sorted, deduplicated lines in byte order, the order comm expects
def lines-save [file: path]: list<string> -> nothing {
    $in | uniq | sort | each { $"($in)\n" } | str join | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}

def lines-load [file: path]: nothing -> list<string> {
    if ($file | path exists) { open --raw $file | lines | where $it != "" } else { [] }
}

# remote parents must exist before an upload; create-folder refuses an existing one
def folder-ensure [parent: string, name: string]: nothing -> bool {
    let listing = cli list -j $parent
    let names = try { $listing.stdout | from json | get name.value } catch { [] }
    if $listing.exit_code == 0 and $name in $names { return true }
    (cli create-folder $parent $name).exit_code == 0
}

# every folder of the target below /my-files, outermost first
def target-ensure [target: string]: nothing -> bool {
    mut parent = "/my-files"
    for part in ($target | str replace --regex '^/my-files/' '' | split row "/") {
        if not (folder-ensure $parent $part) { return false }
        $parent = $"($parent)/($part)"
    }
    true
}

# 0 uploaded, 2 only files changed mid-upload (retry once), 1 anything else; unchanged files are skipped by hash
def upload [source: path, parent: string]: nothing -> int {
    # the cli takes an argument holding * ? [ or { as a glob pattern, any other one as it is
    let literal = if $source =~ '[*?\[{]' { $source | str replace --all --regex '([\[\]{}()*?!+@\\])' '\$1' } else { $source }
    let done = ^proton-drive filesystem upload -j -f create-new-revision -d merge -t $literal $parent | complete
    print --stderr --no-newline $done.stderr
    if $done.exit_code == 0 { return 0 }
    # no summary is the call itself failing: session expired, network down
    let failures = try { $done.stdout | lines | last | from json | get failures } catch { return 1 }
    if not (($failures | describe) =~ '^(list|table)') { return 1 }
    print --stderr $">>> upload failures: ($failures | to json --raw)"
    let real = $failures | get error | where {|error| not ($error | str contains $SKIPPED_ERROR) }
    if ($real | is-empty) { return 0 }
    if ($real | all {|error| $error | str starts-with $CHANGED_ERROR }) { return 2 }
    1
}

# runs `filesystem <verb>` on the paths: those still there; gone_pattern in the error means already gone
def remote-apply [verb: string, gone_pattern: string, paths: list<string>]: nothing -> list<string> {
    let whole = cli $verb -j ...$paths
    if $whole.exit_code == 0 and (all-ok $whole.stdout) { return [] }
    # one unresolvable path fails the whole call before anything moves: retry one by one
    $paths | each {|item|
        let one = cli $verb -j $item
        if $one.exit_code == 0 and (all-ok $one.stdout) { return null }
        if ($one.stderr | str contains $gone_pattern) { return null }
        print --stderr $">>> ($verb) ($item) failed: (error-short $one.stderr) (error-short $one.stdout)"
        $item
    } | compact
}

def remote-apply-batched [verb: string, gone_pattern: string, paths: list<string>]: nothing -> list<string> {
    $paths | chunks $BATCH_COUNT | each {|batch| remote-apply $verb $gone_pattern $batch } | flatten
}

# renames each path (relative to base) to a name unique in the trash, then trashes it and queues it for deletion:
# the paths still remote, a renamed one under its new name
def trash-unique [base: string, rels: list<string>, purge_queue: path]: nothing -> list<string> {
    let attempts = $rels | each {|rel|
        let unique = $"($UNIQUE_PREFIX)(date now | format date '%s%f')"
        let renamed = cli rename $"($base)/($rel)" $unique
        if $renamed.exit_code == 0 {
            {rel: $rel, unique: $unique, failed: false}
        } else if ($renamed.stderr | str contains $GONE) {
            null
        } else {
            print --stderr $">>> rename ($base)/($rel) failed: (error-short $renamed.stderr)"
            {rel: $rel, unique: null, failed: true}
        }
    } | compact
    let renamed = $attempts | where not failed
    let trash_paths = $renamed | each {|r| [$base ($r.rel | path dirname) $r.unique] | where $it != "" | str join "/" }
    let untrashed = remote-apply-batched trash $GONE $trash_paths | each { path basename }
    # the untrashed stay remote under their new names, which the next run's sweep finds again
    lines-load $purge_queue | append ($renamed | get unique | where $it not-in $untrashed) | lines-save $purge_queue
    $attempts | where failed | get rel | append $untrashed
}

# trashes the gone files below remote and queues them for deletion: those still remote
def prune [remote: string, gone: list<string>, purge_queue: path]: nothing -> list<string> {
    let kept = remote-apply-batched trash $GONE ($gone | each {|rel| $"($remote)/($rel)" })
    | each { path relative-to $remote }
    # blob names are content hashes, unique in the trash, so deleting by name cannot hit another item
    let kept_file = mktemp --tmpdir
    let gone_file = mktemp --tmpdir
    $kept | lines-save $kept_file
    $gone | lines-save $gone_file
    let trashed = with-env {LC_ALL: C} { ^comm -23 $gone_file $kept_file } | lines | each { path basename }
    rm --force $kept_file $gone_file
    lines-load $purge_queue | append $trashed | lines-save $purge_queue
    $kept
}

# the upload, retried once if only files changed during it
def upload-settled [source: path, parent: string]: nothing -> bool {
    match (upload $source $parent) {
        0 => true
        2 => {
            print $">>> ($source) changed during the upload, once more"
            (upload $source $parent) == 0
        }
        _ => false
    }
}

# prunes what the source dropped, uploads the rest, clears the remote root of strays: whether all of it succeeded
def mirror [source: path, target: string, state: path]: nothing -> bool {
    let root = $env.PROTON_MIRROR_ROOT
    let root_keep = $env.PROTON_MIRROR_ROOT_KEEP | split row " " | where $it != ""
    let manifest = $env.PROTON_MIRROR_MANIFEST
    let max_gone_percent = $env.PROTON_MIRROR_MAX_GONE_PERCENT | into int
    let remote = $"($target)/($source | path basename)"
    let allow_large = $"($manifest).allow-large"
    let purge_queue = $state | path join offsite-purge.txt

    mut ok = true
    # listed before the upload: a file written during it is in the next run's list and upload
    let current_file = mktemp --tmpdir
    let manifest_file = mktemp --tmpdir
    ^find $source -type f -printf '%P\n' | lines | lines-save $current_file
    let current = lines-load $current_file
    # what may be remote once the upload starts: a run cut short (timeout) still prunes it later
    lines-load $manifest | append $current | lines-save $manifest
    open --raw $manifest | save --force $manifest_file

    # prune before the upload: a full drive takes no new blob until the dropped ones are gone, and an upload-first
    # order never prunes once it is full. The cost: until the upload ends, the remote lacks the newest index blobs
    let gone = with-env {LC_ALL: C} { ^comm -23 $manifest_file $current_file } | lines
    let known_count = lines-load $manifest | length
    let gone_count = $gone | length
    rm --force $current_file $manifest_file
    let kept = if $gone_count > 0 and $gone_count * 100 > $known_count * $max_gone_percent and not ($allow_large | path exists) {
        print $">>> ($gone_count) of ($known_count) uploaded entries are gone locally, over ($max_gone_percent)%;"
        print $">>> not pruning the off-site copy. if intended: touch ($allow_large) and rerun"
        $ok = false
        $gone
    } else {
        rm --force $allow_large
        print $">>> pruning ($gone_count) remote entries the source dropped"
        prune $remote $gone $purge_queue
    }
    if ($kept | is-not-empty) { $ok = false }

    print $">>> ($source) -> ($remote)"
    if not (upload-settled $source $target) { $ok = false }

    # the next run retries what could not be pruned
    $current | append $kept | lines-save $manifest

    # whatever else sits in the remote root an earlier version uploaded
    let listing = cli list -j $root
    let strays = if $listing.exit_code == 0 {
        try { $listing.stdout | from json | get name.value | where $it not-in $root_keep } catch { [] }
    } else { [] }
    if ($strays | is-not-empty) {
        print $">>> trashing ($strays | str join ' ') from ($root), uploaded by an earlier version"
        if (trash-unique $root $strays $purge_queue | is-not-empty) { $ok = false }
    }

    let queued = lines-load $purge_queue
    if ($queued | is-not-empty) {
        print $">>> deleting ($queued | length) trashed entries for good"
        let left = remote-apply-batched delete $TRASH_GONE ($queued | each {|name| $"/trash/($name)" })
        | each { path relative-to /trash }
        $left | lines-save $purge_queue
        if ($left | is-not-empty) { $ok = false }
    }
    $ok
}

def main [mode: string]: nothing -> nothing {
    let target = $env.PROTON_MIRROR_TARGET
    if $mode not-in [mirror upload] {
        print --stderr "usage: proton-mirror mirror|upload"
        exit 2
    }
    if $mode == "mirror" and not ($env.PROTON_MIRROR_MAX_GONE_PERCENT =~ '^[0-9]+$') {
        print --stderr $"proton-mirror: '($env.PROTON_MIRROR_MAX_GONE_PERCENT)' is no percentage"
        exit 2
    }
    if not ($target | str starts-with "/my-files/") {
        print --stderr $"proton-mirror: target '($target)' is not below /my-files"
        exit 2
    }
    let status = (status-of flock --wait $"($LOCK_WAIT_SECONDS)" $env.PROTON_MIRROR_LOCK
        $nu.current-exe --no-config-file $env.CURRENT_FILE locked $mode)
    exit $status
}

def "main locked" [mode: string]: nothing -> nothing {
    let source = $env.PROTON_MIRROR_SOURCE
    let target = $env.PROTON_MIRROR_TARGET
    let state = $env.PROTON_MIRROR_STATE

    if not (file-filled ($state | path join auth-session.json)) {
        print "no proton session; run 'proton-drive-login' on this host once (opens a sign-in url)"
        return
    }
    # an upload trashes nothing, but one of an empty folder (the data not moved in yet, the disk gone) reads as a success
    if $mode == "mirror" {
        source-guard $source $env.PROTON_MIRROR_MARKER
    } else if (^find $source -type f -print -quit | complete | get stdout | is-empty) {
        die $"($source) holds no file: missing, unmounted or not filled yet; refusing to upload"
    }
    # an outage skips the run: the off-site copy stays as the last run left it
    let probe = status-of $env.PROTON_MIRROR_PROBE
    if $probe != 0 { exit $probe }
    proton-events-lock-repair $state
    if not (target-ensure $target) { failed $"cannot create the remote folders of ($target)" }

    let ok = if $mode == "mirror" {
        mirror $source $target $state
    } else {
        print $">>> ($source) -> ($target)/($source | path basename), deleting nothing"
        upload-settled $source $target
    }
    if not $ok { failed "one or more uploads or prunes failed" }
    if $mode == "upload" { touch $env.PROTON_MIRROR_UPLOADED }
    # freshness only on a fully successful run
    exit (status-of $env.PROTON_MIRROR_METRIC (date now | format date "%s"))
}
