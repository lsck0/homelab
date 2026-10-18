# pull-mirror every owned github repo into forgejo; a github outage skips the run with UPSTREAM_UNAVAILABLE

const GITHUB_UPSTREAM = "github"
const GITHUB_API = "https://api.github.com"
const GITHUB_TIMEOUT_S = 30
# the api's largest page
const GITHUB_PAGE_COUNT = 100
const HTTP_NOT_FOUND = 404
const SECONDS_PER_UNIT = {h: 3600, m: 60, s: 1}

def env-require [name: string, why: string]: nothing -> string {
    let value = $env | get --optional $name | default ""
    if $value == "" { error make {msg: $"($name) is unset: ($why)"} }
    $value
}

def token-read [file: path, name: string]: nothing -> string {
    let token = open --raw $file | str trim
    if $token == "" { error make {msg: $"($name) token is empty"} }
    $token
}

# tokens go to curl in a header file, never argv; the unit's private /tmp drops it
def header-file-create [lines: list<string>]: nothing -> path {
    let file = mktemp --tmpdir
    ^chmod 600 $file
    $lines | str join "\n" | save --force $file
    $file
}

# forgejo reports "8h" back as "8h0m0s"
def duration-seconds [text: string]: nothing -> int {
    $text | parse --regex '(?<count>\d+)(?<unit>[hms])' | each {|p| ($p.count | into int) * ($SECONDS_PER_UNIT | get $p.unit) } | math sum
}

# {status, body}: the http status tells a missing repo (404) from a forgejo that failed to answer
def forgejo-call [config: record, method: string, route: string, body?: string]: nothing -> record {
    let out = mktemp --tmpdir
    let data = if $body == null { [] } else { [--data-binary @-] }
    let got = $body | do { ^curl -sS -X $method -o $out -w "%{http_code}" -H $"@($config.forgejo_headers)" ...$data $"($config.forgejo_url)/api/v1($route)" } | complete
    let response = open --raw $out
    rm --force $out
    let status = if $got.exit_code == 0 { $got.stdout | str trim | into int } else { 0 }
    {status: $status, body: $response, error: ($got.stderr | str trim)}
}

def forgejo-ok [response: record]: nothing -> bool {
    $response.status >= 200 and $response.status < 300
}

# a failed page ends the run with its status, an outage's included
def github-repos [config: record]: nothing -> list<record> {
    mut repos = []
    mut page = 1
    loop {
        let url = $"($GITHUB_API)/user/repos?affiliation=owner&per_page=($GITHUB_PAGE_COUNT)&page=($page)"
        let got = do { ^$config.upstream $GITHUB_UPSTREAM curl -fsS --max-time $GITHUB_TIMEOUT_S -H $"@($config.github_headers)" $url } | complete
        if $got.exit_code != 0 {
            print -e $got.stderr
            exit $got.exit_code
        }
        let batch = $got.stdout | from json
        $repos = $repos | append $batch
        if ($batch | length) < $GITHUB_PAGE_COUNT { break }
        $page += 1
    }
    $repos
}

# one of created, corrected, unchanged, skipped, or a problem string
def repo-mirror [config: record, repo: record]: nothing -> record {
    let route = $"/repos/($config.owner)/($repo.name)"
    let existing = forgejo-call $config GET $route
    if $existing.status == $HTTP_NOT_FOUND {
        let body = {
            clone_addr: $repo.clone_url, repo_name: $repo.name, repo_owner: $config.owner,
            service: "github", mirror: true, mirror_interval: $config.interval, private: $repo.private,
            # copied once; github has no incremental feed
            issues: true, labels: true, milestones: true, releases: true, wiki: true
        } | merge (if $repo.private { {auth_token: $config.github_token} } else { {} })
        # the migration clones at once, no sync request needed
        if (forgejo-ok (forgejo-call $config POST /repos/migrate ($body | to json --raw))) {
            return {outcome: created, note: $"($repo.name): mirror created"}
        }
        return {outcome: problem, note: $"($repo.name): migration failed"}
    }
    if not (forgejo-ok $existing) {
        return {outcome: problem, note: $"($repo.name): forgejo answered ($existing.status) ($existing.error)"}
    }
    let mirror = $existing.body | from json
    if not $mirror.mirror {
        # a real repo owns the name; never clobber it
        return {outcome: problem, skipped: true, note: $"($repo.name): exists in Forgejo and is not a mirror, left alone"}
    }
    let outcome = if (duration-seconds $mirror.mirror_interval) == (duration-seconds $config.interval) {
        {outcome: unchanged}
    } else if (forgejo-ok (forgejo-call $config PATCH $route ({mirror_interval: $config.interval} | to json --raw))) {
        {outcome: corrected, note: $"($repo.name): interval corrected to ($config.interval)"}
    } else {
        return {outcome: problem, note: $"($repo.name): could not correct the interval"}
    }
    # a mirror is only as good as its last fetch
    if not (forgejo-ok (forgejo-call $config POST $"($route)/mirror-sync")) {
        return {outcome: problem, note: $"($repo.name): sync request failed"}
    }
    $outcome
}

def main []: nothing -> nothing {
    let forgejo_token = token-read (env-require FORGEJO_TOKEN_FILE "the forgejo token file") Forgejo
    let github_token = token-read (env-require GITHUB_TOKEN_FILE "the github token file") GitHub
    let config = {
        forgejo_url: (env-require FORGEJO_URL "the forgejo base url")
        owner: (env-require FORGEJO_OWNER "the Forgejo user the mirrors belong to")
        interval: (env-require MIRROR_INTERVAL "forgejo re-fetch interval, e.g. 8h")
        upstream: (env-require UPSTREAM "modules/upstream run")
        unavailable: (env-require UPSTREAM_UNAVAILABLE "its exit status for an outage" | into int)
        github_token: $github_token
        forgejo_headers: (header-file-create [$"Authorization: token ($forgejo_token)" "Content-Type: application/json"])
        github_headers: (header-file-create [
            $"Authorization: Bearer ($github_token)" "Accept: application/vnd.github+json" "X-GitHub-Api-Version: 2022-11-28"
        ])
    }

    let repos = github-repos $config
    if ($repos | is-empty) { error make {msg: "GitHub returned no repositories"} }
    print $"GitHub reports ($repos | length) repositories owned by the token's account"

    let results = $repos | each {|repo| repo-mirror $config $repo }
    $results | each {|r| if $r.note? != null { print $r.note } } | ignore
    let count = {|outcome| $results | where outcome == $outcome | length }
    let skipped = $results | where {|r| $r.skipped? == true } | length
    print $"created=(do $count created) corrected=(do $count corrected) unchanged=(do $count unchanged) skipped=($skipped)"
    let problems = do $count problem
    if $problems == 0 {
        print "every GitHub repository is mirrored"
        return
    }
    # forgejo clones from github itself: failures while github is down are the outage's
    if (do { ^$config.upstream $GITHUB_UPSTREAM } | complete).exit_code != 0 { exit $config.unavailable }
    print $"($problems) repositories need attention"
    exit 1
}
