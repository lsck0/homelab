# terraform's state between the workstation and the nas
#
# The nas holds the authoritative state (/srv/nas/terraform/terraform.tfstate, which kopia snapshots); a sync works on
# a local copy and holds the nas lock from before its pull to after its push. A push can still fail (the nas went away
# mid-run), and another deployer may apply in between, so each copy remembers the nas content it last agreed with
# (<local>.synced, a sha256):
#   pull: the nas is unchanged since the agreement: keep the local copy (it holds our unpushed apply, if any). The nas
#         changed and the local copy did not: take the nas copy. Both changed, or another lineage: stop for a human.
#   push: only a nas copy equal to the agreement may be replaced, and only by a newer serial of its lineage.
# Rejected: comparing serials alone. Two deployers that both pulled serial 10 and applied both hold 11, and the second
# push was dropped; with one push failed, the ahead copy later overwrote the other deployer's apply.
#
# The caller passes the transport, so tests run all of this on local files: a record of closures
#   read {|out| ...}   copy the nas state to <out>; returns 0 done, 1 nas unreachable, 2 no state on the nas yet
#   write {|in| ...}   replace the nas state with <in> atomically; returns whether it did
#   lock {|| ...}      hold the nas lock while its stdin stays open: prints "locked" once held, or "busy"
# Every command returns {ok, message} and never exits.

const LOCK_TIMEOUT = 30sec
const RELEASE_TIMEOUT = 30sec
# the holder's stdin writes nothing until the release ends it; this process ending closes it too, so the lock never
# outlives the run
const LOCK_FEED_INTERVAL = 1day
const MAIN_THREAD = 0
const TAG_MAX = 2147483647
const RELEASE = "release"

export def tfstate-dir []: nothing -> path {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state) | path join homelab terraform
}

def meta [file: path]: nothing -> record { open --raw $file | from json | select lineage serial }
def hash-of [file: path]: nothing -> string { open --raw $file | hash sha256 }
def same [a: path, b: path]: nothing -> bool { (hash-of $a) == (hash-of $b) }
def synced-file [local: path]: nothing -> path { $"($local).synced" }

# the hash of the nas content this copy last agreed with, empty before the first agreement
export def tfstate-synced-get [local: path]: nothing -> string {
    try { open --raw (synced-file $local) | str trim } catch { "" }
}

export def tfstate-synced-set [local: path, agreed: path]: nothing -> nothing {
    hash-of $agreed | save --force (synced-file $local)
}

export def tfstate-hash [file: path]: nothing -> string { hash-of $file }

# {ok, message, job, tag}: the job holds the lock until tfstate-lock-release ends its stdin
export def tfstate-lock-acquire [transport: record]: nothing -> record {
    let tag = random int 1..$TAG_MAX
    let holder = $transport.lock
    let job = job spawn {
        (1..
            | each {|_| try { job recv --tag $tag --timeout $LOCK_FEED_INTERVAL } catch { "" } }
            | take until {|message| $message == $RELEASE }
            # raw text: a list stream reaches an external through nu's table renderer
            | to text
            | do $holder
            | lines
            | each {|line| $line | job send --tag $tag $MAIN_THREAD }
            | ignore)
        "" | job send --tag $tag $MAIN_THREAD
    }
    let answer = try { job recv --tag $tag --timeout $LOCK_TIMEOUT } catch { "" }
    if $answer == "locked" { return {ok: true, message: "", job: $job, tag: $tag} }
    # the holder ended already, or never answered
    try { job kill $job }
    let message = if $answer == "busy" {
        "ERROR: another sync holds the terraform state lock on the nas; wait for it to finish."
    } else {
        "ERROR: could not take the terraform state lock: the nas does not answer. Rerun with TF_STATE_OFFLINE=1 to apply from the local copy, which may be behind the nas."
    }
    {ok: false, message: $message, job: null, tag: null}
}

# the holder's stdin ends, which ends it on the nas and drops the lock; safe when nothing is held
export def tfstate-lock-release [lock: record]: nothing -> nothing {
    if $lock.job? == null or $lock.job not-in (job list | get id) { return }
    try { $RELEASE | job send --tag $lock.tag $lock.job }
    # the holder's last word is the empty line it sends when it ends
    try {
        loop { if (job recv --tag $lock.tag --timeout $RELEASE_TIMEOUT) == "" { break } }
    } catch {
        try { job kill $lock.job }
    }
}

# kept beside it under the time it moved, with the agreement it held; nothing is deleted
export def tfstate-set-aside [local: path]: nothing -> string {
    if not ($local | path exists) {
        rm --force (synced-file $local)
        return ""
    }
    let aside = $"($local).(date now | format date '%Y%m%dT%H%M%S.%f').backup"
    mv $local $aside
    if (synced-file $local | path exists) { mv (synced-file $local) $"($aside).synced" }
    $">>> Terraform state: the local copy is set aside as ($aside)"
}

def remote-fetch [transport: record]: nothing -> record {
    let remote = mktemp --tmpdir --suffix .tfstate
    let code = do $transport.read $remote
    {file: $remote, code: $code}
}

def stop [remote: path, message: string]: nothing -> record {
    rm --force $remote
    {ok: false, message: $message}
}

def is-state [file: path]: nothing -> bool {
    try {
        let state = open --raw $file | from json
        ($state.lineage | describe) == "string" and ($state.serial | describe) in [int float]
    } catch { false }
}

# makes <local> current
export def tfstate-pull [transport: record, local: path]: nothing -> record {
    let fetched = remote-fetch $transport
    let remote = $fetched.file
    match $fetched.code {
        0 => {}
        1 => { return (stop $remote "ERROR: the nas does not answer; terraform state not pulled.") }
        2 => {
            rm --force $remote
            if ($local | path exists) {
                return {ok: true, message: ">>> Terraform state: none on the nas yet, the local copy goes up after the apply."}
            }
            return {ok: false, message: ([
                $"ERROR: no terraform state, neither on the nas nor in ($local)."
                "       First deploy of an empty lab: rerun with TF_STATE_FRESH=1."
            ] | str join "\n")}
        }
        _ => { return (stop $remote $"ERROR: reading the nas state failed \(($fetched.code)\).") }
    }
    if not (is-state $remote) { return (stop $remote "ERROR: the nas terraform state is not a terraform state.") }
    let r = meta $remote
    if ($local | path exists) {
        let l = meta $local
        let synced = tfstate-synced-get $local
        if $l.lineage != $r.lineage {
            return (stop $remote ([
                $"ERROR: terraform state lineage differs: nas ($r.lineage) \(serial ($r.serial)\), local ($l.lineage) \(serial ($l.serial)\)."
                "       Keep the right one, delete the other, and rerun."
            ] | str join "\n"))
        }
        if (same $remote $local) {
            rm --force $remote
            tfstate-synced-set $local $local
            return {ok: true, message: $">>> Terraform state: local copy matches the nas \(serial ($r.serial)\)."}
        }
        # the nas is as we left it: the local copy is ours, a push that failed last run
        if $synced != "" and (hash-of $remote) == $synced and $l.serial >= $r.serial {
            rm --force $remote
            return {ok: true, message: $">>> Terraform state: local serial ($l.serial) is ahead of the nas \(($r.serial)\), a push failed last run; keeping it."}
        }
        # the nas moved on; the local copy may only follow when it holds nothing of its own
        if (hash-of $local) != $synced and ($synced != "" or $l.serial >= $r.serial) {
            return (stop $remote ([
                $"ERROR: the nas state \(serial ($r.serial)\) and ($local) \(serial ($l.serial)\) both changed since they last agreed:"
                "       two applies diverged. Compare them (terraform show), keep the one Proxmox matches, delete the other, rerun."
            ] | str join "\n"))
        }
    }
    mv --force $remote $local
    ^chmod 600 $local
    tfstate-synced-set $local $local
    {ok: true, message: $">>> Terraform state: pulled from the nas \(serial ($r.serial)\)."}
}

# after an apply, under the lock; the local copy stays ahead when the nas is gone, and the next run pushes it
export def tfstate-push [transport: record, local: path]: nothing -> record {
    if not ($local | path exists) { return {ok: true, message: ""} }
    let l = meta $local
    let synced = tfstate-synced-get $local
    let fetched = remote-fetch $transport
    let remote = $fetched.file
    match $fetched.code {
        0 => {
            if (same $remote $local) {
                rm --force $remote
                tfstate-synced-set $local $local
                return {ok: true, message: ""}
            }
            let r = meta $remote
            if (hash-of $remote) != $synced or $l.lineage != $r.lineage or $l.serial <= $r.serial {
                return (stop $remote ([
                    $"ERROR: the nas state \(($r.lineage), serial ($r.serial)\) is not the one this run started from; local is ($l.lineage), serial ($l.serial)."
                    "       Not pushed: compare them, keep the one Proxmox matches, delete the other, rerun."
                ] | str join "\n"))
            }
            rm --force $remote
        }
        1 => {
            rm --force $remote
            return {ok: true, message: "WARNING: the nas does not answer; terraform state not pushed, the next sync pushes it."}
        }
        2 => { rm --force $remote }
        _ => { return (stop $remote $"ERROR: reading the nas state failed \(($fetched.code)\).") }
    }
    if not (do $transport.write $local) {
        return {ok: true, message: "WARNING: terraform state push failed; the next sync pushes it."}
    }
    tfstate-synced-set $local $local
    {ok: true, message: $">>> Terraform state: pushed to the nas \(serial ($l.serial)\)."}
}
