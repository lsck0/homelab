# point the lab's cloudflare A records at the house's public address
#
# contract: every listed name converges to one A record with the address and proxy flag asked for, an A record of the
# address no name asks for is deleted, and the address is recorded as synced only when all of it converged; an
# unchanged synced address is not checked against cloudflare until DDNS_RESYNC_MIN passed.
# security: the token reaches curl in a mode 600 header file, never on a command line.

const API_URL_DEFAULT = "https://api.cloudflare.com/client/v4"
const RESYNC_MIN_DEFAULT = 60
# a hung call must not hold the timer's next run
const CURL_TIMEOUT_S = 20
# cloudflare's "automatic" ttl
const RECORD_TTL = 1
# the lab publishes some tens of names; one page holds them all, a second page fails loudly
const RECORDS_PAGE_SIZE = 1000
const IPV4 = '^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# one api call: the parsed body, or null once the failure is logged
def --wrapped api [header: path, ...args: string]: nothing -> any {
    let run = do { ^curl -sS --fail-with-body --max-time $CURL_TIMEOUT_S -H $"@($header)" -H 'Content-Type: application/json' ...$args } | complete
    if $run.exit_code != 0 {
        print -e $"ddns: ($args | str join ' ') failed: ($run.stdout) ($run.stderr | str trim)"
        return null
    }
    let body = try { $run.stdout | from json } catch { null }
    if ($body | get --optional success) != true {
        print -e $"ddns: ($args | str join ' ') answered unsuccessfully: ($run.stdout)"
        return null
    }
    $body
}

def record-sync [header: path, records_url: string, ip: string, name: string, proxied: bool]: nothing -> bool {
    let found = api $header -G --data-urlencode $"name=($name)" --data-urlencode "type=A" $records_url
    if $found == null { return false }
    let data = {type: "A", name: $name, content: $ip, ttl: $RECORD_TTL, proxied: $proxied} | to json --raw
    if ($found.result | is-empty) {
        if (api $header -X POST --data $data $records_url) == null { return false }
        print $"ddns: created ($name) -> ($ip) \(proxied: ($proxied)\)"
        return true
    }
    let first = $found.result.0
    if $first.content != $ip or $first.proxied != $proxied {
        if (api $header -X PUT --data $data $"($records_url)/($first.id)") == null { return false }
        print $"ddns: updated ($name): ($first.content) -> ($ip) \(proxied: ($proxied)\)"
    }
    # a duplicate splits resolution between a live and a dead address
    $found.result | skip 1 | all {|duplicate|
        let deleted = (api $header -X DELETE $"($records_url)/($duplicate.id)") != null
        if $deleted { print $"ddns: deleted duplicate record ($duplicate.id) of ($name)" }
        $deleted
    }
}

# the house's records no listed name asks for: null when the listing failed
def records-stale [header: path, records_url: string, ip: string, wanted: list<string>]: nothing -> any {
    let found = (api $header -G --data-urlencode "type=A" --data-urlencode $"content.exact=($ip)"
        --data-urlencode $"per_page=($RECORDS_PAGE_SIZE)" $records_url)
    if $found == null { return null }
    if $found.result_info.total_pages > 1 {
        print -e $"ddns: more than ($RECORDS_PAGE_SIZE) records hold ($ip)"
        return null
    }
    # content filtered here too, whatever the api did with the filter
    $found.result | where {|r| $r.content == $ip and not ($r.name in $wanted) }
}

# the count of records not converged
def records-sync [header: path, ip: string, records: list<record>]: nothing -> int {
    let api_url = $env.DDNS_API_URL? | default $API_URL_DEFAULT
    let zones = api $header -G --data-urlencode $"name=($env.DDNS_ZONE)" $"($api_url)/zones"
    if $zones == null or ($zones.result | length) != 1 {
        print -e $"ddns: no zone id for ($env.DDNS_ZONE)"
        return 1
    }
    let records_url = $"($api_url)/zones/($zones.result.0.id)/dns_records"

    let failures = $records | where {|r| not (record-sync $header $records_url $ip $r.name $r.proxied) } | length
    if $failures != 0 { return $failures }

    let stale = records-stale $header $records_url $ip ($records | get name)
    if $stale == null { return 1 }
    $stale | where {|r|
        let deleted = (api $header -X DELETE $"($records_url)/($r.id)") != null
        if $deleted { print $"ddns: deleted ($r.name), which no route publishes" }
        not $deleted
    } | length
}

def main []: nothing -> nothing {
    let records_file = $env.DDNS_RECORDS
    let state_file = $env.DDNS_STATE_DIR | path join state
    let resync_min = $env.DDNS_RESYNC_MIN? | default $RESYNC_MIN_DEFAULT | into int

    let ip = open --raw $env.DDNS_ADDRESS_FILE | lines | get --optional 0 | default "" | split row " " | first
    if $ip == "" {
        print "ddns: no public address learned yet, nothing to point the records at"
        return
    }
    if not ($ip =~ $IPV4) {
        print -e $"ddns: ($env.DDNS_ADDRESS_FILE) holds no ipv4 address: '($ip)'"
        exit 1
    }

    # the record list too: a name the lab gains is published on the next run, not after the resync
    let state = $"($ip) (open --raw $records_file | hash sha256)"
    if ($state_file | path exists) and (open --raw $state_file) == $state {
        let age = (date now) - (ls $state_file | get 0.modified)
        if $age < ($resync_min * 1min) { return }
    }

    let header = ^mktemp | str trim
    ^chmod 600 $header
    $"Authorization: Bearer (open --raw $env.DDNS_TOKEN_FILE | str trim)\n" | save --force $header
    let failures = try { records-sync $header $ip (open --raw $records_file | from json) } catch {|e|
        print -e $"ddns: ($e.msg)"
        1
    }
    rm --force $header

    if $failures != 0 {
        print -e $"ddns: ($failures) record\(s\) not converged, ($ip) stays unsynced for the next run"
        exit 1
    }
    $state | save --force $"($state_file).tmp"
    ^mv $"($state_file).tmp" $state_file
}
