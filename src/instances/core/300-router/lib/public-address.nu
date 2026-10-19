# learn the house's public addresses from the fritzbox and publish each as a hosts line coredns serves
#
# usage: public-address v4|prefix6, with PUBLIC_URL (the fritzbox's WANIPConn1 control url), PUBLIC_FILE, PUBLIC_HOST
# and, for prefix6, PUBLIC_PREFIX_LENGTH
#   v4       the public ipv4 address (GetExternalIPAddress), which the ddns records follow
#   prefix6  the delegated ipv6 prefix (X_AVM_DE_GetIPv6Prefix): the router is v4-only
# The fritzbox's upnp igd answers both without a login and without a third party. No answer, or an answer that is no
# address: the last published line stays and the run fails.

const SERVICE = "urn:schemas-upnp-org:service:WANIPConnection:1"
const TIMEOUT_S = 10

def die [message: string]: nothing -> nothing {
    print -e $message
    exit 1
}

def field [answer: string, name: string]: nothing -> string {
    $answer | parse --regex $"<($name)>\(?<value>[^<]*\)</($name)>" | get --optional value.0 | default ""
}

def upnp-ask [action: string]: nothing -> string {
    let url = $env.PUBLIC_URL
    let envelope = ('<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        + 's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        + $'<u:($action) xmlns:u="($SERVICE)"/></s:Body></s:Envelope>')
    let reply = do {
        (^curl -sSf --max-time $TIMEOUT_S -H 'Content-Type: text/xml; charset="utf-8"'
            -H $"SoapAction: ($SERVICE)#($action)" --data $envelope $url)
    } | complete
    if $reply.exit_code != 0 {
        die $"the fritzbox answers no upnp at ($url): is \"Statusinformationen ueber UPnP uebertragen\" on?"
    }
    $reply.stdout
}

def hosts-line-publish [address: string]: nothing -> nothing {
    let file = $env.PUBLIC_FILE
    $"($address) ($env.PUBLIC_HOST)\n" | save --force $"($file).tmp"
    ^mv $"($file).tmp" $file
}

def "main v4" []: nothing -> nothing {
    let address = field (upnp-ask GetExternalIPAddress) NewExternalIPAddress
    let octets = $address | split row "."
    let valid = (($octets | length) == 4
        and ($octets | all {|o| $o =~ '^[0-9]{1,3}$' and ($o | into int) <= 255 })
        and $address != "0.0.0.0")
    if not $valid {
        die $"the fritzbox answered no public ipv4 address: '($address)'"
    }
    hosts-line-publish $address
    print $"house address: ($address)"
}

def "main prefix6" []: nothing -> nothing {
    let answer = upnp-ask X_AVM_DE_GetIPv6Prefix
    let prefix = field $answer NewIPv6Prefix
    let length = field $answer NewPrefixLength
    let length_expected = $env.PUBLIC_PREFIX_LENGTH
    # a hex group first: never "::", never the empty answer of a house without ipv6
    if not ($prefix =~ '^[0-9a-fA-F]{1,4}:[0-9a-fA-F:]*$') {
        die $"the fritzbox answered no ipv6 prefix: '($prefix)'"
    }
    if $length != $length_expected {
        die $"the fritzbox delegates ($prefix)/($length), the lab expects a /($length_expected) \(net.nix publicPrefixLength\)"
    }
    hosts-line-publish $prefix
    print $"house prefix: ($prefix)/($length)"
}

def main []: nothing -> nothing {
    die "usage: public-address v4|prefix6"
}
