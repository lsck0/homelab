# sync the syncthing folder with its proton drive copy both ways: this front holds the proton lock and refuses what
# must not sync, the engine (proton-bisync.py, whose header says how) does the rest
#
# usage: proton-bisync sync|resync, the environment as kopia.nix's bisyncEnv sets it
#   sync    hourly: what changed on either side since the last run reaches the other
#   resync  the baseline, by hand only: both sides merged, nothing deleted
# A sync deleting past the engine's limit syncs nothing until STATE/allow-large is touched, for one run.

# the engine's status for a run refused by that limit
const EXIT_GUARD = 3
# flock's status when an hourly run finds the lock taken; nothing else in a run exits with it
const EXIT_LOCK_BUSY = 99

def "main locked" [mode: string]: nothing -> nothing {
    let state = $env.PROTON_BISYNC_STATE
    let allow_large = $state | path join allow-large
    if not (file-filled $env.PROTON_BISYNC_SESSION) {
        die "no proton session: run proton-drive-login on this host once (opens a sign-in url)"
    }
    source-guard $env.PROTON_BISYNC_SOURCE $env.PROTON_BISYNC_MARKER
    if $mode == "sync" and not (file-filled ($state | path join state.json)) {
        die "no baseline yet: once both sides are as they should be, systemctl start proton-bisync-resync"
    }
    # an outage skips the run: both sides stay as they are
    let probe = status-of $env.PROTON_BISYNC_PROBE
    if $probe != 0 { exit $probe }
    proton-events-lock-repair $env.PROTON_DRIVE_CACHE_DIR

    let allow = $mode == "sync" and ($allow_large | path exists)
    if $allow { print $">>> ($allow_large): this run may delete past the limit" }
    let status = with-env {PROTON_BISYNC_ALLOW_LARGE: (if $allow { "1" } else { "0" })} {
        status-of proton-bisync-engine $mode
    }
    if $status == $EXIT_GUARD {
        die $">>> nothing synced. if the loss is intended: touch ($allow_large); systemctl start proton-bisync"
    }
    if $status != 0 { exit $status }
    rm --force $allow_large
    exit (status-of $env.PROTON_BISYNC_METRIC (date now | format date "%s"))
}

def main [mode: string]: nothing -> nothing {
    if $mode not-in [sync resync] {
        print --stderr "usage: proton-bisync sync|resync"
        exit 2
    }
    # an hourly run behind a repository upload that holds proton for hours skips instead of piling up
    let wait = if $mode == "sync" { [--nonblock --conflict-exit-code $"($EXIT_LOCK_BUSY)"] } else { [] }
    let status = status-of flock ...$wait $env.PROTON_BISYNC_LOCK $nu.current-exe --no-config-file $env.CURRENT_FILE locked $mode
    if $status == $EXIT_LOCK_BUSY {
        print $"another off-site run holds ($env.PROTON_BISYNC_LOCK); skipping this hour"
        return
    }
    exit $status
}
