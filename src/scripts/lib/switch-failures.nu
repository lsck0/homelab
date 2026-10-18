#!/usr/bin/env -S nu --no-config-file --stdin
# on a guest whose switch-to-configuration failed, with its output on stdin: what failed it, nothing when only units
# no configuration declares failed. A transient unit (podman's healthcheck runs, systemd-run) fails mid-restart by
# design, and one systemd already collected is not found any more, which no declared unit ever is. sync.nu and
# instances/preconfigured/213-external-share/tests/share.nix judge a switch by it.

const FAILED_PREFIX = "warning: the following units failed: "

def unit-property [unit: string, property: string]: nothing -> string {
    let shown = ^systemctl show -P $property -- $unit
    $shown | str trim
}

def main []: string -> nothing {
    let units = $in | lines | where { str starts-with $FAILED_PREFIX }
        | each { str substring ($FAILED_PREFIX | str length).. | split row "," | str trim } | flatten | where $it != ""
    if ($units | is-empty) {
        print "the switch itself"
        return
    }
    $units | where {|unit| (unit-property $unit Transient) == "no" and (unit-property $unit LoadState) != "not-found" }
        | each { print $in } | ignore
}
