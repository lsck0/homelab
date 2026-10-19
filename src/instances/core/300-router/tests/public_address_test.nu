# lib/public-address.nu with curl faked as the fritzbox: a table of its answers, each run checked for its exit, the
# hosts line it leaves and the upnp action it asked for
#
# usage: public_address_test.nu <public-address executable>

const URL = "http://192.168.178.1:49000/igdupnp/control/WANIPConn1"
const SERVICE = "urn:schemas-upnp-org:service:WANIPConnection:1"
# curl's exit for a refused connection
const CURL_REFUSED = 7

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

# the fritzbox's response to an action, as it sends it
def answer-set [fake: path, action: string, fields: record]: nothing -> nothing {
    let body = $fields | transpose name value | each {|f| $"<($f.name)>($f.value)</($f.name)>" } | str join "\n"
    $'<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:($action)Response xmlns:u="($SERVICE)">
($body)
</u:($action)Response>
</s:Body>
</s:Envelope>
' | save --force ($fake | path join answer)
}

# expected: the hosts line, or null for none published; message: what the run prints, or null
def expect [run: closure, fake: path, file: path, action: string, name: string, exit_code: int, expected: any, message: any] {
    let run = do $run | complete
    let output = $run.stdout + $run.stderr
    if $run.exit_code != $exit_code { fail $"($name): exit ($run.exit_code), expected ($exit_code): ($output)" }
    if $expected == null {
        if ($file | path exists) { fail $"($name): an address was published: (open --raw $file)" }
    } else {
        let published = open --raw $file | str trim --right --char "\n"
        if $published != $expected { fail $"($name): published '($published)', expected '($expected)'" }
    }
    if $message != null and not ($output | str contains $message) { fail $"($name): no '($message)' in: ($output)" }
    let args = open --raw ($fake | path join curl) | lines
    if not ($"SoapAction: ($SERVICE)#($action)" in $args) { fail $"($name): the upnp action ($action) was not asked for" }
    if not ($URL in $args) { fail $"($name): the fritzbox was not asked" }
    print $"ok: ($name)"
}

def v4-check [script: path, fake: path, dir: path]: nothing -> nothing {
    let host = "wg.lsck0.dev"
    let file = $dir | path join hosts
    let action = "GetExternalIPAddress"
    let run = {|| with-env { PUBLIC_FILE: $file, PUBLIC_HOST: $host } { ^$script v4 } }
    let answer = {|address| answer-set $fake $action { NewExternalIPAddress: $address } }
    rm --force ($fake | path join answer)
    expect $run $fake $file $action "v4, upnp off: nothing published, the setting named" 1 null "Statusinformationen ueber UPnP"
    do $answer ""
    expect $run $fake $file $action "v4, no address yet: nothing published" 1 null "no public ipv4"
    do $answer "87.148.120.182"
    expect $run $fake $file $action "the address published" 0 $"87.148.120.182 ($host)" null
    for bad in ["0.0.0.0" "87.148.120" "87.148.120.300" "2003::1"] {
        do $answer $bad
        expect $run $fake $file $action $"($bad): the last address kept" 1 $"87.148.120.182 ($host)" "no public ipv4"
    }
    do $answer "87.148.121.9"
    expect $run $fake $file $action "the address changed" 0 $"87.148.121.9 ($host)" null
}

def prefix6-check [script: path, fake: path, dir: path]: nothing -> nothing {
    let host = "house-prefix.lsck0.dev"
    let file = $dir | path join prefix6
    let action = "X_AVM_DE_GetIPv6Prefix"
    let run = {|| with-env { PUBLIC_FILE: $file, PUBLIC_HOST: $host, PUBLIC_PREFIX_LENGTH: "56" } { ^$script prefix6 } }
    let answer = {|prefix, length|
        answer-set $fake $action { NewIPv6Prefix: $prefix, NewPrefixLength: $length, NewValidLifetime: 14035 }
    }
    rm --force ($fake | path join answer)
    expect $run $fake $file $action "prefix6, upnp off: nothing published" 1 null "Statusinformationen ueber UPnP"
    do $answer "" ""
    expect $run $fake $file $action "a house without ipv6: nothing published" 1 null "no ipv6 prefix"
    do $answer "2003:f7:8f41:6700::" "56"
    expect $run $fake $file $action "the prefix published" 0 $"2003:f7:8f41:6700:: ($host)" null
    do $answer "::" "56"
    expect $run $fake $file $action "the unspecified address: the last prefix kept" 1 $"2003:f7:8f41:6700:: ($host)" "no ipv6 prefix"
    do $answer "2003:f7:8f41:6700::" "64"
    expect $run $fake $file $action "another length: the last prefix kept" 1 $"2003:f7:8f41:6700:: ($host)" "expects a /56"
    do $answer "2003:f7:8f42:1200::" "56"
    expect $run $fake $file $action "the prefix rotated" 0 $"2003:f7:8f42:1200:: ($host)" null
    rm ($fake | path join answer)
    expect $run $fake $file $action "the fritzbox gone: the last prefix kept" 1 $"2003:f7:8f42:1200:: ($host)" "answers no upnp"
}

def main [script: path]: nothing -> nothing {
    let script = $script | path expand
    let dir = ^mktemp -d | str trim
    let fake = $dir | path join fake
    let bin = $dir | path join bin
    mkdir $fake $bin
    let curl = $bin | path join curl
    $"#!(which bash | get path.0)
printf '%s\\n' \"$@\" > ($fake)/curl
[ -f ($fake)/answer ] || exit ($CURL_REFUSED)
cat ($fake)/answer
" | save $curl
    ^chmod +x $curl

    with-env { PUBLIC_URL: $URL, PATH: ($env.PATH | prepend $bin) } {
        v4-check $script $fake $dir
        prefix6-check $script $fake $dir
    }
    if (do { ^$script } | complete).exit_code == 0 { fail "no subcommand: the run passed" }
}
