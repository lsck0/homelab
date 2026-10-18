# mirror the official arch repos (core/extra/multilib, x86_64) from a tier-1 rsync upstream into a served tree
#
# usage: archmirror-sync, with ARCHMIRROR_UPSTREAM (rsync module root ending in /), ARCHMIRROR_TARGET,
# ARCHMIRROR_BWLIMIT_KBPS and ARCHMIRROR_PROBE (exits 0 while the upstream answers, modules/upstream's unavailable
# while it is down); the unit holds the flock
#
# The official two-stage method: upstream's lastupdate byte-equal to ours means nothing changed, so an hourly tick
# costs one tiny transfer, not a walk of the 120 GiB tree. Otherwise a full pass, --delay-updates staging every
# changed file in .~tmp~ and renaming the batch into place only after a clean transfer, so nginx never serves a
# half-synced tree. Only after the pass succeeded is the stamp fetched first installed: a failed pass keeps the old
# one, so the next run passes again, and a newer stamp from after the pass started would claim files never fetched.

# the upstream's change marker, a unix timestamp at the module root
const STAMP = "lastupdate"
# no data for this long aborts the pass; 10 min outlasts a busy tier-1 that stalls while it renames its own batch
const IO_TIMEOUT_SECONDS = 600
const CONNECT_TIMEOUT_SECONDS = 60

def --wrapped status-of [...command: string]: nothing -> int {
    try { run-external ...$command; 0 } catch {|e| $e.exit_code? | default 1 }
}

# an outage is the probe's status; any other failure is this run's
def upstream-failed []: nothing -> int {
    let probe = status-of $env.ARCHMIRROR_PROBE
    if $probe != 0 { $probe } else { 1 }
}

def mirror-sync [upstream: string, target: path, bwlimit_kbps: string, stamp_new: path]: nothing -> int {
    let timeouts = [$"--timeout=($IO_TIMEOUT_SECONDS)" $"--contimeout=($CONNECT_TIMEOUT_SECONDS)"]
    if (status-of rsync -q --no-motd ...$timeouts $"($upstream)($STAMP)" $stamp_new) != 0 {
        print --stderr $"archmirror: cannot fetch ($upstream)($STAMP), the mirror stays as it is"
        return (upstream-failed)
    }
    let stamp = $target | path join $STAMP
    if ($stamp | path exists) and (open --raw $stamp_new | into binary) == (open --raw $stamp | into binary) {
        print "archmirror: upstream unchanged, nothing to sync"
        return 0
    }
    # --safe-links drops links escaping the tree, the repos' relative links into pool/ stay; the stamp is ours to set
    let pass = (status-of rsync -rtlH -p --safe-links --no-motd --delay-updates --delete-after --delete-excluded
        ...$timeouts $"--bwlimit=($bwlimit_kbps)"
        $"--filter=P /($STAMP)" $"--exclude=/($STAMP)" --exclude=/iso --exclude=/sources '--exclude=*.links.tar.gz*'
        $upstream $"($target)/")
    if $pass != 0 { return (upstream-failed) }
    # a rename, so a reader sees the old stamp or the new one, never a torn file; dotfiles are never served
    let staged = $target | path join $".($STAMP).new"
    ^install -m 0644 $stamp_new $staged
    mv --force $staged $stamp
    print $"archmirror: synced to upstream ($STAMP) (open --raw $stamp | into binary | decode utf-8 | str trim)"
    0
}

def main []: nothing -> nothing {
    let upstream = $env.ARCHMIRROR_UPSTREAM
    let target = $env.ARCHMIRROR_TARGET
    let bwlimit_kbps = $env.ARCHMIRROR_BWLIMIT_KBPS
    if not ($upstream =~ '^rsync://.+/$') {
        print --stderr $"archmirror: '($upstream)' is no rsync:// module root ending in /"
        exit 1
    }
    if not ($bwlimit_kbps =~ '^[1-9][0-9]*$') {
        print --stderr $"archmirror: bandwidth cap '($bwlimit_kbps)' is no positive KiB/s"
        exit 1
    }
    mkdir $target
    let stamp_new = mktemp --tmpdir
    let status = mirror-sync $upstream $target $bwlimit_kbps $stamp_new
    rm --force $stamp_new
    exit $status
}
