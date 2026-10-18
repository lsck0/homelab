# learn the house's public ipv6 prefix from the fritzbox and publish it as a hosts line coredns serves
#
# the router is v4-only, so the fritzbox's upnp igd (X_AVM_DE_GetIPv6Prefix) tells the delegated prefix, without a
# login. No answer, no prefix or another length: the last published prefix stays and the run fails.

const SERVICE = "urn:schemas-upnp-org:service:WANIPConnection:1"
const ACTION = "X_AVM_DE_GetIPv6Prefix"
const TIMEOUT_S = 10

def die [message: string]: nothing -> nothing {
    print -e $message
    exit 1
}

def field [answer: string, name: string]: nothing -> string {
    $answer | parse --regex $"<($name)>\(?<value>[^<]*\)</($name)>" | get --optional value.0 | default ""
}

def main []: nothing -> nothing {
    let url = $env.PREFIX_URL
    let file = $env.PREFIX_FILE
    let host = $env.PREFIX_HOST
    let length_expected = $env.PREFIX_LENGTH

    let envelope = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        + 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        + $'<u:($ACTION) xmlns:u="($SERVICE)"/></s:Body></s:Envelope>')
    let reply = do {
        (^curl -sSf --max-time $TIMEOUT_S -H 'Content-Type: text/xml; charset="utf-8"'
            -H $"SoapAction: ($SERVICE)#($ACTION)" --data $envelope $url)
    } | complete
    if $reply.exit_code != 0 {
        die $"the fritzbox answers no upnp at ($url): is \"Statusinformationen ueber UPnP uebertragen\" on?"
    }
    let prefix = field $reply.stdout NewIPv6Prefix
    let length = field $reply.stdout NewPrefixLength

    # a hex group first: never "::", never the empty answer of a house without ipv6
    if not ($prefix =~ '^[0-9a-fA-F]{1,4}:[0-9a-fA-F:]*$') {
        die $"the fritzbox answered no ipv6 prefix: '($prefix)'"
    }
    if $length != $length_expected {
        die $"the fritzbox delegates ($prefix)/($length), the lab expects a /($length_expected) \(net.nix publicPrefixLength\)"
    }

    $"($prefix) ($host)\n" | save --force $"($file).tmp"
    ^mv $"($file).tmp" $file
    print $"house prefix: ($prefix)/($length)"
}
