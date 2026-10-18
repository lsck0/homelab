# renew proton's forwarded port, point the dnat set at it and hand it to qbittorrent

const TABLE = "proton-port"
const SET = "proton_port"
# qbittorrent's webui (120-internal-qbittorrent/instance.nix port)
const WEBUI_PORT = 80
# proton's documented request: private port 1, public port 0 (the gateway picks it)
const PRIVATE_PORT = 1
const PUBLIC_PORT = 0

def die [message: string]: nothing -> nothing {
    print $message
    exit 1
}

def port-map [gateway: string, proto: string, lease_s: string]: nothing -> int {
    let run = do { ^natpmpc -g $gateway -a $PRIVATE_PORT $PUBLIC_PORT $proto $lease_s } | complete
    let out = $run.stdout + $run.stderr
    if $run.exit_code != 0 { die $"natpmpc failed for ($proto): ($out)" }
    let port = $out | parse --regex 'Mapped public port (?<port>\d+)' | get --optional port.0
    if $port == null { die $"no port in the ($proto) reply: ($out)" }
    $port | into int
}

def main []: nothing -> nothing {
    let peer = $env.PEER_HOST
    let api = $"http://($peer):($WEBUI_PORT)/api/v2"
    let port = ["udp" "tcp"] | each { port-map $env.GATEWAY $in $env.LEASE_S } | last

    # dnat first, so the port leads somewhere before qbittorrent announces it
    let current = ^nft -j list set ip $TABLE $SET | from json | get nftables | each { $in.set?.elem?.0? } | compact
        | get --optional 0
    if $current != $port {
        ^nft flush set ip $TABLE $SET
        ^nft add element ip $TABLE $SET $"{ ($port) }"
        print $"forwarding ($port) to ($peer)"
    }

    # compare against the client's real port, not a note
    let preferences = do { ^curl -sf $"($api)/app/preferences" } | complete
    let have = if $preferences.exit_code == 0 { $preferences.stdout | from json | get --optional listen_port }
    if $have == $port { return }

    let preferences_new = {listen_port: $port, random_port: false, upnp: false} | to json --raw
    let set = do { ^curl -sf -X POST $"($api)/app/setPreferences" --data-urlencode $"json=($preferences_new)" } | complete
    if $set.exit_code != 0 { die $"could not give qBittorrent the new port ($port)" }
    print $"qBittorrent is now on ($port)"
}
