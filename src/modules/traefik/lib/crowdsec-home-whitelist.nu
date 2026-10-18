# never let crowdsec ban the house (the lab's own ranges are modules/traefik's static whitelist)
#
# the house is its public v4 address and its v6 prefix, which the router serves to the v4-only lab by name
# (instances/core/300-router public-address, public-prefix). No v4 address: the file stays as it is. No prefix: the
# file keeps the one it has.

const CONFIG_DEFAULT = "/var/lib/crowdsec/config"
const CONTAINER_DEFAULT = "crowdsec"
const ITEM_INDENT = "    "

def --wrapped podman-run [...args: string]: nothing -> nothing {
    let ran = ^podman ...$args | complete
    if $ran.exit_code != 0 {
        error make {msg: $"podman ($args | str join ' ') failed: ($ran.stderr | str trim)"}
    }
}

# the first address of a getent answer, "" when the name does not resolve
def address-first [database: string, name: string]: nothing -> string {
    let answer = ^getent $database $name | complete
    if $answer.exit_code != 0 { return "" }
    $answer.stdout | lines | get --optional 0 | default "" | split row " " | first
}

def main []: nothing -> nothing {
    let host = $env.PUBLIC_HOST
    let prefix_host = $env.PUBLIC_PREFIX_HOST
    let prefix_length = $env.PUBLIC_PREFIX_LENGTH
    let config = $env.CROWDSEC_CONFIG? | default $CONFIG_DEFAULT
    let container = $env.CONTAINER? | default $CONTAINER_DEFAULT
    let out = $config | path join parsers s02-enrich home-whitelist.yaml

    let v4 = address-first ahostsv4 $host
    if $v4 == "" {
        print $"($host) does not resolve yet; leaving the whitelist alone"
        return
    }

    # getent hosts, not ahostsv6: that one asks no AAAA on a host without ipv6; an A answer has no colon
    let network = address-first hosts $prefix_host
    let prefix = if ($network | str contains ":") {
        $"($network)/($prefix_length)"
    } else if ($out | path exists) {
        let kept = open --raw $out | lines | parse --regex ('^' + $ITEM_INDENT + '- "(?<cidr>.*/.*)"$') | get --optional cidr.0 | default ""
        print $"($prefix_host) does not resolve; keeping the prefix ($kept | default --empty '(none)')"
        $kept
    } else {
        ""
    }

    let body = [
        "name: homelab/home-whitelist"
        'description: "The addresses the house is seen as. Generated; do not edit."'
        "whitelist:"
        '  reason: "home network"'
        "  ip:"
        $'($ITEM_INDENT)- "($v4)"'
    ] | append (if $prefix == "" { [] } else { ["  cidr:" $'($ITEM_INDENT)- "($prefix)"'] }) | str join "\n" | $"($in)\n"

    let current = if ($out | path exists) { open --raw $out } else { "" }
    if $current != $body {
        mkdir ($out | path dirname)
        $body | save --force $"($out).tmp"
        mv --force $"($out).tmp" $out
        print $"home whitelist updated: ($v4) ($prefix | default --empty '(no prefix)')"
        # sighup, not a restart
        podman-run kill --signal HUP $container
    }

    # lift any existing ban on the house; the whitelist above stops new ones
    podman-run exec $container cscli decisions delete --ip $v4
    if $prefix != "" {
        # --contained: the bans inside the prefix; without it only those spanning all of it
        podman-run exec $container cscli decisions delete --range $prefix --contained
    }
    print $"home whitelist in place \(($v4) ($prefix | default --empty '(no prefix)')\)"
}
