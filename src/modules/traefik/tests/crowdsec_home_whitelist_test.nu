# lib/crowdsec-home-whitelist.nu with getent and podman faked: a table of what the router serves, each run checked
# for the whitelist it leaves, whether crowdsec was told to reload, and which bans it lifted
#
# usage: crowdsec_home_whitelist_test.nu <lib/crowdsec-home-whitelist.nu>

const PUBLIC_HOST = "wg.lsck0.dev"
const PREFIX_HOST = "house-prefix.lsck0.dev"
const PREFIX_LENGTH = "56"
const DELETE_PREFIX = "exec crowdsec cscli decisions delete "
const RELOAD = "kill --signal HUP crowdsec"

# ahostsv4 answers the A record, hosts the AAAA record or else the A record, as glibc does
const FAKE_GETENT = '
def main [database: string, name: string] {
    let read = {|kind| let file = $env.FAKE | path join $"($name).($kind)"; if ($file | path exists) { open --raw $file | str trim } else { "" } }
    let a = do $read a
    let aaaa = do $read aaaa
    match $database {
        "ahostsv4" => { if $a == "" { exit 2 }; print $"($a)      STREAM ($name)" }
        "hosts" => { if $aaaa != "" { print $"($aaaa) ($name)" } else if $a != "" { print $"($a)  ($name)" } else { exit 2 } }
        _ => { exit 1 }
    }
}
'
const FAKE_PODMAN = '
def --wrapped main [...args: string] { $"($args | str join (char space))\n" | save --append ($env.FAKE | path join podman) }
'

def fail [message: string] {
    error make {msg: $"FAIL: ($message)"}
}

# the router's answers: [the house's A record, the prefix name's AAAA record, its A record]; null answers nothing
def serve [fake: path, answers: list<any>]: nothing -> nothing {
    let files = [$"($PUBLIC_HOST).a" $"($PREFIX_HOST).aaaa" $"($PREFIX_HOST).a"]
    rm --force ...($files | each {|file| $fake | path join $file })
    $files | zip $answers | where { $in.1 != null } | each {|pair| $pair.1 | save ($fake | path join $pair.0) } | ignore
}

def check [case: record, out: path, calls: list<string>]: nothing -> nothing {
    if $case.ip == null {
        if ($out | path exists) { fail $"($case.name): a whitelist was written" }
    } else {
        let whitelist = open $out | get whitelist
        let ip = $whitelist.ip | str join " "
        let cidr = $whitelist.cidr? | default [] | str join " "
        if $ip != $case.ip { fail $"($case.name): ip '($ip)', expected '($case.ip)'" }
        if $cidr != ($case.cidr | default "") { fail $"($case.name): cidr '($cidr)', expected '($case.cidr)'" }
    }
    let reloaded = $calls | any { str contains "kill" }
    if $case.reloaded and not ($RELOAD in $calls) { fail $"($case.name): crowdsec was not reloaded" }
    if not $case.reloaded and $reloaded { fail $"($case.name): crowdsec was reloaded" }
    let lifted = $calls | where { str starts-with $DELETE_PREFIX } | str substring ($DELETE_PREFIX | str length)..
    if $lifted != $case.lifted { fail $"($case.name): lifted ($lifted | to nuon), expected ($case.lifted | to nuon)" }
    print $"ok: ($case.name)"
}

def main [script: path]: nothing -> nothing {
    let root = mktemp --directory
    let fake = $root | path join fake
    let bin = $root | path join bin
    let config = $root | path join config
    let out = $config | path join parsers s02-enrich home-whitelist.yaml
    mkdir $fake $bin
    for tool in [[name body]; [getent $FAKE_GETENT] [podman $FAKE_PODMAN]] {
        let file = $bin | path join $tool.name
        $"#!($nu.current-exe) --no-config-file\n($tool.body)" | save $file
        ^chmod +x $file
    }

    let old = "2003:f7:8f41:6700::/56"
    let new = "2003:f7:8f42:1200::/56"
    let cases = [
        {name: "no v4 address yet: nothing written, nothing lifted", serve: [null "2003:f7:8f41:6700::" null],
            ip: null, cidr: null, reloaded: false, lifted: []}
        {name: "no prefix yet: the v4 address alone", serve: ["203.0.113.9" null null],
            ip: "203.0.113.9", cidr: null, reloaded: true, lifted: ["--ip 203.0.113.9"]}
        {name: "the prefix learned", serve: ["203.0.113.9" "2003:f7:8f41:6700::" null],
            ip: "203.0.113.9", cidr: $old, reloaded: true, lifted: ["--ip 203.0.113.9" $"--range ($old) --contained"]}
        {name: "unchanged: no reload, bans lifted again", serve: ["203.0.113.9" "2003:f7:8f41:6700::" null],
            ip: "203.0.113.9", cidr: $old, reloaded: false, lifted: ["--ip 203.0.113.9" $"--range ($old) --contained"]}
        {name: "v4 rotated, prefix unknown: the prefix kept", serve: ["198.51.100.4" null null],
            ip: "198.51.100.4", cidr: $old, reloaded: true, lifted: ["--ip 198.51.100.4" $"--range ($old) --contained"]}
        {name: "the prefix name answering v4 only is no prefix: kept", serve: ["198.51.100.4" null "198.51.100.4"],
            ip: "198.51.100.4", cidr: $old, reloaded: false, lifted: ["--ip 198.51.100.4" $"--range ($old) --contained"]}
        {name: "the prefix rotated", serve: ["198.51.100.4" "2003:f7:8f42:1200::" null],
            ip: "198.51.100.4", cidr: $new, reloaded: true, lifted: ["--ip 198.51.100.4" $"--range ($new) --contained"]}
        {name: "nothing resolves: the file as it is, nothing lifted", serve: [null null null],
            ip: "198.51.100.4", cidr: $new, reloaded: false, lifted: []}
    ]
    let environment = {
        PATH: ($env.PATH | prepend $bin)
        PUBLIC_HOST: $PUBLIC_HOST
        PUBLIC_PREFIX_HOST: $PREFIX_HOST
        PUBLIC_PREFIX_LENGTH: $PREFIX_LENGTH
        CROWDSEC_CONFIG: $config
        FAKE: $fake
    }
    for case in $cases {
        serve $fake $case.serve
        rm --force ($fake | path join podman)
        let ran = with-env $environment { ^$nu.current-exe --no-config-file $script | complete }
        if $ran.exit_code != 0 { fail $"($case.name): the script failed: ($ran.stderr)" }
        let calls = if ($fake | path join podman | path exists) { open --raw ($fake | path join podman) | lines } else { [] }
        check $case $out $calls
    }
}
