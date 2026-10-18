# lib/public-prefix.nu with curl faked as the fritzbox: a table of its answers, each run checked for its exit, the
# hosts line it leaves and the upnp action it asked for
#
# usage: public_prefix_test.nu <public-prefix executable>

const URL = "http://192.168.178.1:49000/igdupnp/control/WANIPConn1"
const HOST = "house-prefix.lsck0.dev"
const SOAP_ACTION = "SoapAction: urn:schemas-upnp-org:service:WANIPConnection:1#X_AVM_DE_GetIPv6Prefix"
# curl's exit for a refused connection
const CURL_REFUSED = 7

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

# the fritzbox's X_AVM_DE_GetIPv6Prefix response, as it sends it
def answer-set [fake: path, prefix: string, length: string]: nothing -> nothing {
    $'<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:X_AVM_DE_GetIPv6PrefixResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
<NewIPv6Prefix>($prefix)</NewIPv6Prefix>
<NewPrefixLength>($length)</NewPrefixLength>
<NewValidLifetime>14035</NewValidLifetime>
<NewPreferedLifetime>1435</NewPreferedLifetime>
</u:X_AVM_DE_GetIPv6PrefixResponse>
</s:Body>
</s:Envelope>
' | save --force ($fake | path join answer)
}

# expected: the hosts line, or null for none published; message: what the run prints, or null
def expect [script: path, fake: path, file: path, name: string, exit_code: int, expected: any, message: any] {
    let run = do { ^$script } | complete
    let output = $run.stdout + $run.stderr
    if $run.exit_code != $exit_code { fail $"($name): exit ($run.exit_code), expected ($exit_code): ($output)" }
    if $expected == null {
        if ($file | path exists) { fail $"($name): a prefix was published: (open --raw $file)" }
    } else {
        let published = open --raw $file | str trim --right --char "\n"
        if $published != $expected { fail $"($name): published '($published)', expected '($expected)'" }
    }
    if $message != null and not ($output | str contains $message) { fail $"($name): no '($message)' in: ($output)" }
    let args = open --raw ($fake | path join curl) | lines
    if not ($SOAP_ACTION in $args) { fail $"($name): the upnp action was not asked for" }
    if not ($URL in $args) { fail $"($name): the fritzbox was not asked" }
    print $"ok: ($name)"
}

def main [script: path]: nothing -> nothing {
    let script = $script | path expand
    let dir = ^mktemp -d | str trim
    let fake = $dir | path join fake
    let bin = $dir | path join bin
    let file = $dir | path join prefix6
    mkdir $fake $bin
    let curl = $bin | path join curl
    $"#!(which bash | get path.0)
printf '%s\\n' \"$@\" > ($fake)/curl
[ -f ($fake)/answer ] || exit ($CURL_REFUSED)
cat ($fake)/answer
" | save $curl
    ^chmod +x $curl

    with-env {
        PREFIX_URL: $URL, PREFIX_FILE: $file, PREFIX_HOST: $HOST, PREFIX_LENGTH: "56"
        PATH: ($env.PATH | prepend $bin)
    } {
        expect $script $fake $file "upnp off: nothing published, the setting named" 1 null "Statusinformationen ueber UPnP"
        answer-set $fake "" ""
        expect $script $fake $file "a house without ipv6: nothing published" 1 null "no ipv6 prefix"
        answer-set $fake "2003:f7:8f41:6700::" "56"
        expect $script $fake $file "the prefix published" 0 $"2003:f7:8f41:6700:: ($HOST)" null
        answer-set $fake "::" "56"
        expect $script $fake $file "the unspecified address: the last prefix kept" 1 $"2003:f7:8f41:6700:: ($HOST)" "no ipv6 prefix"
        answer-set $fake "2003:f7:8f41:6700::" "64"
        expect $script $fake $file "another length: the last prefix kept" 1 $"2003:f7:8f41:6700:: ($HOST)" "expects a /56"
        answer-set $fake "2003:f7:8f42:1200::" "56"
        expect $script $fake $file "the prefix rotated" 0 $"2003:f7:8f42:1200:: ($HOST)" null
        rm ($fake | path join answer)
        expect $script $fake $file "the fritzbox gone: the last prefix kept" 1 $"2003:f7:8f42:1200:: ($HOST)" "answers no upnp"
    }
}
