#!/usr/bin/env -S nu --no-config-file
# fetch arch-dotfiles at <ref> into <dir> and print the commit, only when it is signed by the pinned key
#
# the build trusts the package list, mirror/pkgbuilds and mirror/overrides.conf of this commit, and everything built
# from them gets the repo key's signature. The rule is arch-dotfiles' bootstrap clone_verify: `git verify-commit` passes
# AND the primary key of the signature is the pinned one. The key file is read from the unverified commit, which is
# harmless: a commit signed by any other key it ships fails the fingerprint check. Not covered, as in bootstrap: a
# replay of an older signed commit of <ref>.
#
# <dir> is the host's alone: the containers get it read-only, so nothing a build runs can plant git config or hooks
# that this script would execute as root on the next run.

# arch-dotfiles' SIGNING_KEY_FILE
const KEY_FILE = "configs/core/gnupg/luca-sandrock.pub.asc"
const FETCH_TIMEOUT_S = 900
# a v4 fingerprint as gpg prints it
const FINGERPRINT_PATTERN = '^[0-9A-F]{40}$'
const VERDICTS = [GOODSIG BADSIG EXPSIG EXPKEYSIG REVKEYSIG ERRSIG]

def die [message: string]: nothing -> nothing {
    print -e $"fetch: ($message)"
    exit 1
}

def --wrapped git-in [dir: path, ...args: string]: nothing -> record {
    do { ^git -C $dir ...$args } | complete
}

# the [GNUPG:] status lines of a verify, as words
def gpg-status [raw: string]: nothing -> list<list<string>> {
    $raw | lines | each { split row --regex '\s+' } | where { ($in | first) == "[GNUPG:]" }
}

# the commit's signature by the pinned primary key, or the reason it is refused
def signature-check [dir: path, commit: string, fingerprint: string]: nothing -> nothing {
    let gnupg_home = mktemp --directory
    let verify = with-env {GNUPGHOME: $gnupg_home} {
        let key = git-in $dir show $"($commit):($KEY_FILE)"
        if $key.exit_code == 0 { $key.stdout | ^gpg --batch --quiet --import | complete | ignore }
        let verify = git-in $dir verify-commit --raw $commit
        do { ^gpgconf --kill all } | complete | ignore
        $verify
    }
    rm --recursive --force $gnupg_home
    let status = gpg-status $"($verify.stdout)\n($verify.stderr)"
    # VALIDSIG <signing key> ... <primary key>: the primary key is the tenth field after the keyword
    let signer = $status | where { ($in | get -o 1) == VALIDSIG } | each { get -o 11 } | compact | get -o 0 | default ""
    if $verify.exit_code == 0 and $signer == $fingerprint { return }
    let verdict = $status | each { get -o 1 } | where $it in $VERDICTS | str join " "
    let gpg = if $verdict == "" { "NOSIG" } else { $verdict }
    let primary = if $signer == "" { "none" } else { $signer }
    die $"($commit) is not signed by ($fingerprint) \(gpg: ($gpg), primary key: ($primary)\), refusing to build it; the published snapshot stays"
}

# upstream: modules/upstream's run; the fetch is retried, an outage of the source's host exits with its status
def main [source: string, ref: string, dir: path, fingerprint: string, upstream: path, upstream_name: string]: nothing -> nothing {
    if $fingerprint !~ $FINGERPRINT_PATTERN { die $"'($fingerprint)' is not a v4 fingerprint" }
    if not ($dir | path join .git | path exists) {
        rm --recursive --force $dir
        ^git init -q $dir
    }
    let fetched = with-env {UPSTREAM_TIMEOUT_S: ($FETCH_TIMEOUT_S | into string)} {
        do { ^$upstream $upstream_name git -C $dir fetch -q --depth 1 $source $ref } | complete
    }
    if $fetched.exit_code != 0 {
        print -e $fetched.stderr
        exit $fetched.exit_code
    }
    let commit = git-in $dir rev-parse --verify "FETCH_HEAD^{commit}"
    if $commit.exit_code != 0 { die $"($source) ($ref) fetched no commit" }
    let commit = $commit.stdout | str trim
    signature-check $dir $commit $fingerprint
    ^git -C $dir checkout -q --force --detach $commit
    ^git -C $dir clean -qfdx
    print $commit
}
