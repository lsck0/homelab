#!/usr/bin/env -S nu --no-config-file
# record a night skipped for a third-party outage in the served status, nothing else
#
# the served snapshot, its db and the failure counts stay the last night's; status.json gains `unavailable` and
# `skipped`, which the next publish drops. status.txt keeps its mtime, so archbuild-if-stale tries again.

const SKIPPED_PREFIX = "skipped:    "

def file-replace [file: path, content: string]: nothing -> nothing {
    $content | save --force $"($file).tmp"
    mv --force $"($file).tmp" $file
}

def main [served: path, upstream: string, ...upstreams: string]: nothing -> nothing {
    # the build container names the upstream: only one this build calls reaches the status and the metrics
    if $upstream not-in $upstreams {
        print -e $"skip: '($upstream)' is none of the build's upstreams \(($upstreams | str join ' ')\)"
        exit 1
    }
    let now = date now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ"
    let status_json = $served | path join status.json
    let status_txt = $served | path join status.txt

    let previous = if ($status_json | path exists) { open --raw $status_json | from json } else { {} }
    file-replace $status_json ($previous | merge {unavailable: $upstream, skipped: $now, running: null} | to json --indent 2)

    let kept = if ($status_txt | path exists) {
        open --raw $status_txt | lines | where { not ($in | str starts-with $SKIPPED_PREFIX) }
    } else {
        []
    }
    let content = [$"($SKIPPED_PREFIX)($now), ($upstream) unavailable; the last snapshot keeps serving"] | append $kept
    $content | str join "\n" | $"($in)\n" | save --force $"($status_txt).tmp"
    if ($status_txt | path exists) { ^touch -r $status_txt $"($status_txt).tmp" }
    mv --force $"($status_txt).tmp" $status_txt
}
