# wires the media stack via app apis; idempotent, runs on a timer
#
# every address comes from the environment (lib/recyclarr.nix, or src/tests/media-stack.nu); a missing one stops the
# run before it touches anything. It always exits 0: a pending step is retried on the next run.

# the jellyfin api key the arrs' library notifications use (122-internal-jellyfin mints one per consumer)
const JELLYFIN_KEY = "jellyfin-key-arr"
# when radarr starts looking
const MIN_AVAILABILITY = "announced"
# jellyfin account that owns the lab
const OWNER_USER = "luca"
# seerr's permission bits REQUEST (32) and AUTO_APPROVE (128): the owner's requests go straight to the arrs
const OWNER_PERMISSIONS = 160
const SEERR_USERS_TAKE = 100
const LABS_ARRS = [radarr sonarr lidarr]
const INDEXER_APP_PROFILE = 1
const INDEXER_PRIORITY = 25
# languages in preference order
const SUBTITLE_LANGUAGES_DEFAULT = "de en"
# no-account providers; opensubtitles.com needs one
const SUBTITLE_PROVIDERS_DEFAULT = "podnapisi gestdown tvsubtitles yifysubtitles"

def env-require [name: string]: nothing -> string {
    let value = $env | get --optional $name | default ""
    if $value == "" { error make {msg: $"($name) is unset"} }
    $value
}

def config-load []: nothing -> record {
    let hosts = [QBIT PROWLARR RADARR SONARR LIDARR JELLYFIN] | each {|name|
        {name: ($name | str downcase), host: (env-require $"($name)_HOST"), port: (env-require $"($name)_PORT" | into int)}
    } | reduce --fold {} {|it, acc| $acc | insert $it.name {host: $it.host, port: $it.port, url: $"http://($it.host):($it.port)"} }
    {
        tokens: (env-require TOKEN_DIR)
        secrets: (env-require SECRET_DIR)
        indexers: (env-require INDEXERS | split row " " | where $it != "")
        jellyseerr_url: (env-require JELLYSEERR_URL)
        bazarr_url: (env-require BAZARR_URL)
        # where jellyseerr links the owner to
        radarr_public_url: (env-require RADARR_PUBLIC_URL)
        sonarr_public_url: (env-require SONARR_PUBLIC_URL)
        # the router's socks port isolated per destination
        tor: {host: (env-require TOR_HOST), port: (env-require TOR_PORT | into int)}
        # jellyseerr's initialisation wants a mail address for the jellyfin admin it imports
        jellyseerr_admin_email: (env-require JELLYSEERR_ADMIN_EMAIL)
        subtitle_languages: ($env.SUBTITLE_LANGUAGES? | default $SUBTITLE_LANGUAGES_DEFAULT | split row " " | where $it != "")
        subtitle_providers: ($env.SUBTITLE_PROVIDERS? | default $SUBTITLE_PROVIDERS_DEFAULT | split row " " | where $it != "")
    } | merge $hosts
}

def file-read [file: path]: nothing -> any {
    try { open --raw $file | str trim } catch { null } | if $in == "" { null } else { $in }
}

def token-read [config: record, name: string]: nothing -> any { file-read ($config.tokens | path join $"($name).token") }
def secret-read [config: record, name: string]: nothing -> any { file-read ($config.secrets | path join $name) }

# null when the call failed or the app answered an error
def request [method: string, url: string, headers: record, body?: any, content_type: string = "application/json"]: nothing -> any {
    let headers = $headers | items {|k, v| [$k $v] } | flatten
    try {
        match $method {
            "GET" => { http get --raw --headers $headers $url }
            "DELETE" => { http delete --raw --headers $headers $url }
            "POST" => { http post --raw --headers $headers --content-type $content_type $url ($body | default "") }
            "PUT" => { http put --raw --headers $headers --content-type $content_type $url ($body | default "") }
        } | if ($in | is-empty) { {} } else { $in | from json }
    } catch { null }
}

def api [method: string, url: string, key: string, body?: any]: nothing -> any {
    if $body == null {
        request $method $url {X-Api-Key: $key}
    } else {
        request $method $url {X-Api-Key: $key} ($body | to json --raw)
    }
}

def done [message: string]: nothing -> record { print $message; {pending: false} }
def later [message: string]: nothing -> record { print $message; {pending: true} }

def row-of [rows: any, implementation: string]: nothing -> any {
    $rows | default [] | where implementation == $implementation | get --optional 0
}

# field(name; value) of an *arr row: sets one entry of its .fields
def field-set [name: string, value: any]: record -> record {
    update fields { each {|f| if $f.name == $name { $f | upsert value $value } else { $f } } }
}

# existing rows go stale when an address or setting changes; correct them
def row-correct [label: string, collection: string, key: string, current: record, want: record]: nothing -> list<record> {
    if $current == $want { return [] }
    if (api PUT $"($collection)/($current.id)?forceSave=true" $key $want) != null {
        [(done $"($label): corrected")]
    } else {
        [(later $"($label): correction failed")]
    }
}

# prowlarr's sync never rewrites the address of an indexer it already pushed, so a moved prowlarr strands them all
def prowlarr-indexers-correct [config: record, name: string, base: string, key: string]: nothing -> list<record> {
    let prefix = $"($config.prowlarr.url)/"
    api GET $"($base)/indexer" $key | default [] | where {|row| $row.name | str ends-with "(Prowlarr)" } | each {|row|
        let want = $row | update fields { each {|f|
            if $f.name == baseUrl { $f | update value { str replace --regex '^https?://[^/]+/' $prefix } } else { $f }
        } }
        row-correct $"($name)/indexer ($row.name)" $"($base)/indexer" $key $row $want
    } | flatten
}

def servarr-wire [config: record, name: string, version: string, category_field: string, category: string, ...roots: string]: nothing -> list<record> {
    let key = secret-read $config $"($name)-key"
    if $key == null { return [(later $"($name): no API key")] }
    let qbit_password = secret-read $config qbittorrent-pass
    if $qbit_password == null { return [(later $"($name): no qBittorrent password")] }
    let base = $"(($config | get $name).url)/api/($version)"
    if (api GET $"($base)/system/status" $key) == null { return [(later $"($name): unreachable")] }
    let indexers = if $name == prowlarr { [] } else { prowlarr-indexers-correct $config $name $base $key }

    let current = row-of (api GET $"($base)/downloadclient" $key) QBittorrent
    let client = if $current != null {
        row-correct $"($name)/qbittorrent" $"($base)/downloadclient" $key $current (
            $current | field-set host $config.qbit.host | field-set port $config.qbit.port
        )
    } else {
        let body = row-of (api GET $"($base)/downloadclient/schema" $key) QBittorrent
        | merge {name: qBittorrent, enable: true, priority: 1, removeCompletedDownloads: true, removeFailedDownloads: true}
        | field-set host $config.qbit.host | field-set port $config.qbit.port
        | field-set username admin | field-set password $qbit_password | field-set $category_field $category
        if (api POST $"($base)/downloadclient?forceSave=true" $key $body) != null {
            [(done $"($name): added qBittorrent download client")]
        } else {
            [(later $"($name): adding qBittorrent failed")]
        }
    }

    let folders = $roots | each {|root|
        if (api GET $"($base)/rootfolder" $key | default [] | any {|f| $f.path == $root }) { return [] }
        let body = if $version == v1 {
            # lidarr root folders need default profiles
            {
                name: ($root | path basename), path: $root
                defaultQualityProfileId: (api GET $"($base)/qualityprofile" $key | get 0.id)
                defaultMetadataProfileId: (api GET $"($base)/metadataprofile" $key | get 0.id)
                defaultMonitorOption: all, defaultNewItemMonitorOption: all, defaultTags: [], isCalibreLibrary: false
            }
        } else {
            {path: $root}
        }
        if (api POST $"($base)/rootfolder" $key $body) != null {
            [(done $"($name): added root folder ($root)")]
        } else {
            [(later $"($name): adding root folder ($root) failed")]
        }
    } | flatten
    $indexers ++ $client ++ $folders
}

# library changes on import and rename
def jellyfin-notify-set [config: record]: record -> record {
    merge {onDownload: true, onUpgrade: true, onRename: true}
    | field-set host $config.jellyfin.host | field-set port $config.jellyfin.port | field-set updateLibrary true
}

def jellyfin-notify-wire [config: record, name: string]: nothing -> list<record> {
    let key = secret-read $config $"($name)-key"
    if $key == null { return [(later $"($name): no API key")] }
    let jellyfin_key = token-read $config $JELLYFIN_KEY
    if $jellyfin_key == null { return [(later $"($name): waiting for the Jellyfin API key")] }
    let base = $"(($config | get $name).url)/api/v3"
    let rows = api GET $"($base)/notification" $key
    if $rows == null { return [(later $"($name): unreachable")] }
    let current = row-of $rows MediaBrowser
    if $current != null {
        return (row-correct $"($name)/jellyfin" $"($base)/notification" $key $current ($current | jellyfin-notify-set $config))
    }
    let body = row-of (api GET $"($base)/notification/schema" $key) MediaBrowser
    | jellyfin-notify-set $config | merge {name: Jellyfin} | field-set apiKey $jellyfin_key
    if (api POST $"($base)/notification?forceSave=true" $key $body) != null {
        [(done $"($name): added the Jellyfin library-update notification")]
    } else {
        [(later $"($name): adding the Jellyfin notification failed")]
    }
}

def prowlarr-apps-wire [config: record, base: string, key: string, apps: list]: nothing -> list<record> {
    let wired = [[implementation name]; [Radarr radarr] [Sonarr sonarr] [Lidarr lidarr]] | each {|app|
        let url = ($config | get $app.name).url
        let app_key = secret-read $config $"($app.name)-key"
        if $app_key == null { return [(later $"prowlarr: no ($app.name) API key")] }
        let current = row-of $apps $app.implementation
        if $current != null {
            return (row-correct $"prowlarr/($app.name)" $"($base)/applications" $key $current (
                $current | field-set baseUrl $url | field-set prowlarrUrl $config.prowlarr.url
            ))
        }
        let body = row-of (api GET $"($base)/applications/schema" $key) $app.implementation
        | merge {name: $app.name, syncLevel: fullSync}
        | field-set prowlarrUrl $config.prowlarr.url | field-set baseUrl $url | field-set apiKey $app_key
        if (api POST $"($base)/applications?forceSave=true" $key $body) != null {
            [(done $"prowlarr: connected ($app.name)")]
        } else {
            [(later $"prowlarr: connecting ($app.name) failed")]
        }
    } | flatten
    # apps of removed services fail every sync; the three above are the only ones the lab has
    let removed = $apps | where name not-in $LABS_ARRS | each {|app|
        if (api DELETE $"($base)/applications/($app.id)" $key) != null { done $"prowlarr: removed stale application ($app.id)" }
    } | compact
    $wired ++ $removed
}

# a tor socks5 proxy in front of the indexers; stale, every search times out
def prowlarr-tor-wire [config: record, base: string, key: string, tag: int]: nothing -> list<record> {
    let set = {|row| $row | field-set host $config.tor.host | field-set port $config.tor.port }
    let current = row-of (api GET $"($base)/indexerproxy" $key) Socks5
    if $current != null {
        return (row-correct prowlarr/tor-proxy $"($base)/indexerproxy" $key $current (do $set $current))
    }
    let body = do $set (row-of (api GET $"($base)/indexerproxy/schema" $key) Socks5) | merge {name: tor, tags: [$tag]}
    if (api POST $"($base)/indexerproxy?forceSave=true" $key $body) != null {
        [(done $"prowlarr: added Tor SOCKS5 indexer proxy ($config.tor.host):($config.tor.port)")]
    } else {
        # an unreachable router must not fail the run
        [(done "prowlarr: Tor indexer proxy not added (is the router up?), retried next run")]
    }
}

def prowlarr-indexers-add [config: record, base: string, key: string]: nothing -> list<record> {
    let have = api GET $"($base)/indexer" $key | default [] | get definitionName
    let missing = $config.indexers | where $it not-in $have
    if ($missing | is-empty) { return [] }
    let schema = api GET $"($base)/indexer/schema" $key | default []
    $missing | each {|definition|
        let found = $schema | where definitionName == $definition
        if ($found | is-empty) { return (done $"prowlarr: unknown indexer definition '($definition)'") }
        let body = $found | first | merge {enable: true, appProfileId: $INDEXER_APP_PROFILE, priority: $INDEXER_PRIORITY}
        # prowlarr tests the site even with forceSave
        if (api POST $"($base)/indexer?forceSave=true" $key $body) != null {
            done $"prowlarr: added indexer ($definition)"
        } else {
            done $"prowlarr: indexer ($definition) unreachable, skipped \(retried next run\)"
        }
    }
}

def prowlarr-wire [config: record]: nothing -> list<record> {
    let base = $"($config.prowlarr.url)/api/v1"
    let key = secret-read $config prowlarr-key
    if $key == null { return [(later "prowlarr: no API key")] }
    let apps = api GET $"($base)/applications" $key
    if $apps == null { return [(later "prowlarr: unreachable")] }
    let wired = prowlarr-apps-wire $config $base $key $apps

    let tag = api GET $"($base)/tag" $key | default [] | where label == tor | get --optional 0.id
    | if $in == null { api POST $"($base)/tag" $key {label: tor} | get --optional id } else { $in }
    let tor = if $tag == null { [(later "prowlarr: could not create the tor tag")] } else { prowlarr-tor-wire $config $base $key $tag }
    let added = prowlarr-indexers-add $config $base $key
    let tagged = if $tag == null { [] } else {
        api GET $"($base)/indexer" $key | default [] | where {|i| $tag not-in ($i.tags? | default []) } | each {|i|
            let indexer = api GET $"($base)/indexer/($i.id)" $key
            let body = $indexer | upsert tags (($indexer.tags? | default []) | append $tag)
            if (api PUT $"($base)/indexer/($i.id)" $key $body) != null { done $"prowlarr: indexer ($i.id) now goes through Tor" }
        } | compact
    }
    $wired ++ $tor ++ $added ++ $tagged
}

def seerr [session: string, method: string, url: string, body?: record]: nothing -> any {
    let headers = {Cookie: $session}
    if $body == null { request $method $url $headers } else {
        request $method $url $headers ($body | to json --raw)
    }
}

# the password goes in the request body, never argv; the session cookie comes back
def seerr-login [config: record, base: string, initialised: bool]: nothing -> any {
    let password = open --raw ($config.secrets | path join jellyfin-admin-pass)
    let body = if $initialised {
        {username: admin, password: $password}
    } else {
        {
            username: admin, password: $password, hostname: $config.jellyfin.host, port: $config.jellyfin.port
            useSsl: false, urlBase: "", email: $config.jellyseerr_admin_email, serverType: 2
        }
    }
    let response = try {
        http post --full --content-type application/json $"($base)/auth/jellyfin" ($body | to json --raw)
    } catch { return null }
    let session = $response.headers.response | where {|h| ($h.name | str downcase) == set-cookie }
    | each {|h| $h.value | split row ";" | first } | str join "; "
    if (seerr $session GET $"($base)/auth/me") == null { null } else { $session }
}

# the first server of a kind follows the lab's addresses and keys; its id is read-only on the way back in
def seerr-server-correct [session: string, base: string, kind: string, label: string, set: record]: nothing -> list<record> {
    let current = seerr $session GET $"($base)/settings/($kind)" | default [] | get --optional 0
    if $current == null { return [(later $"jellyseerr: initialised but has no ($label) server")] }
    let want = $current | merge $set
    if $current == $want { return [] }
    if (seerr $session PUT $"($base)/settings/($kind)/($current.id)" ($want | reject id)) != null {
        [(done $"jellyseerr: ($label) server corrected")]
    } else {
        [(later $"jellyseerr: correcting the ($label) server failed")]
    }
}

def seerr-correct [config: record, session: string, base: string, keys: record]: nothing -> list<record> {
    let radarr = seerr-server-correct $session $base radarr Radarr {
        apiKey: $keys.radarr, hostname: $config.radarr.host, port: $config.radarr.port, minimumAvailability: $MIN_AVAILABILITY
    }
    let sonarr = seerr-server-correct $session $base sonarr Sonarr {
        apiKey: $keys.sonarr, hostname: $config.sonarr.host, port: $config.sonarr.port
    }
    # unapproved requests never reach radarr
    let users = seerr $session GET $"($base)/user?take=($SEERR_USERS_TAKE)" | get --optional results | default []
    let owner = $users | where {|u| $u.displayName? == $OWNER_USER or $u.jellyfinUsername? == $OWNER_USER } | get --optional 0.id
    let permissions = if $owner == null {
        [(later $"jellyseerr: no user called ($OWNER_USER)")]
    } else if (seerr $session GET $"($base)/user/($owner)" | get --optional permissions) == $OWNER_PERMISSIONS {
        []
    } else if (seerr $session PUT $"($base)/user/($owner)" {permissions: $OWNER_PERMISSIONS}) != null {
        [(done $"jellyseerr: ($OWNER_USER) may now approve its own requests")]
    } else {
        [(later $"jellyseerr: could not set permissions for ($OWNER_USER)")]
    }
    let defaults = if (seerr $session GET $"($base)/settings/main" | get --optional defaultPermissions) == $OWNER_PERMISSIONS {
        []
    } else if (seerr $session POST $"($base)/settings/main" {defaultPermissions: $OWNER_PERMISSIONS}) != null {
        [(done "jellyseerr: default permissions corrected")]
    } else {
        [(later "jellyseerr: could not set default permissions")]
    }
    $radarr ++ $sonarr ++ $permissions ++ $defaults
}

def seerr-initialise [config: record, session: string, base: string, keys: record]: nothing -> list<record> {
    seerr $session GET $"($base)/settings/jellyfin/library?sync=true" | ignore
    let ids = seerr $session GET $"($base)/settings/jellyfin/library" | default [] | get id | str join ","
    seerr $session GET $"($base)/settings/jellyfin/library?enable=($ids)" | ignore

    let radarr_profile = api GET $"($config.radarr.url)/api/v3/qualityprofile" $keys.radarr | get 0
    let sonarr_profile = api GET $"($config.sonarr.url)/api/v3/qualityprofile" $keys.sonarr | get 0
    let radarr = {
        name: Radarr, hostname: $config.radarr.host, port: $config.radarr.port, apiKey: $keys.radarr, useSsl: false
        baseUrl: "", activeProfileId: $radarr_profile.id, activeProfileName: $radarr_profile.name
        activeDirectory: /data/media/movies, minimumAvailability: $MIN_AVAILABILITY, tags: [], is4k: false
        isDefault: true, externalUrl: $config.radarr_public_url, syncEnabled: true, preventSearch: false
    }
    if (seerr $session POST $"($base)/settings/radarr" $radarr) == null { return [(later "jellyseerr: adding Radarr failed")] }
    let sonarr = {
        name: Sonarr, hostname: $config.sonarr.host, port: $config.sonarr.port, apiKey: $keys.sonarr, useSsl: false
        baseUrl: "", activeProfileId: $sonarr_profile.id, activeProfileName: $sonarr_profile.name
        activeDirectory: /data/media/tv, activeAnimeProfileId: $sonarr_profile.id
        activeAnimeProfileName: $sonarr_profile.name, activeAnimeDirectory: /data/media/anime, seriesType: standard
        animeSeriesType: anime, tags: [], animeTags: [], is4k: false, isDefault: true, enableSeasonFolders: true
        externalUrl: $config.sonarr_public_url, syncEnabled: true, preventSearch: false
    }
    if (seerr $session POST $"($base)/settings/sonarr" $sonarr) == null { return [(later "jellyseerr: adding Sonarr failed")] }
    if (seerr $session POST $"($base)/settings/initialize" {}) != null { [(done "jellyseerr: initialised")] } else { [] }
}

def jellyseerr-wire [config: record]: nothing -> list<record> {
    let base = $"($config.jellyseerr_url)/api/v1"
    let public = request GET $"($base)/settings/public" {}
    if $public == null { return [(later "jellyseerr: unreachable")] }
    let initialised = $public.initialized? == true
    let keys = {radarr: (secret-read $config radarr-key), sonarr: (secret-read $config sonarr-key)}
    if $keys.radarr == null or $keys.sonarr == null or (token-read $config $JELLYFIN_KEY) == null {
        return [(later "jellyseerr: waiting for radarr/sonarr/jellyfin")]
    }
    let session = seerr-login $config $base $initialised
    if $session == null { return [(later "jellyseerr: Jellyfin login failed")] }
    if $initialised { seerr-correct $config $session $base $keys } else { seerr-initialise $config $session $base $keys }
}

def bazarr-wire [config: record]: nothing -> list<record> {
    let base = $"($config.bazarr_url)/api"
    let key = token-read $config bazarr-key
    let radarr_key = secret-read $config radarr-key
    let sonarr_key = secret-read $config sonarr-key
    if $key == null or $radarr_key == null or $sonarr_key == null { return [(later "bazarr: waiting for API keys")] }
    let current = request GET $"($base)/system/settings" {X-API-KEY: $key}
    if $current == null { return [(later "bazarr: unreachable")] }

    # audio_only_include is required, else bazarr fails with a KeyError on indexing
    let items = $config.subtitle_languages | enumerate | each {|l|
        {id: ($l.index + 1), language: $l.item, audio_exclude: "False", audio_only_include: "False", hi: "False", forced: "False"}
    }
    let profile = [{
        profileId: 1, name: ($config.subtitle_languages | str join "+"), cutoff: null, items: $items
        mustContain: [], mustNotContain: [], originalFormat: false, tag: null
    }]
    # sent every run, not only when unconfigured
    let form = [
        [settings-general-use_radarr true]
        [settings-general-use_sonarr true]
        [settings-radarr-ip $config.radarr.host]
        [settings-radarr-port $config.radarr.port]
        [settings-radarr-apikey $radarr_key]
        [settings-sonarr-ip $config.sonarr.host]
        [settings-sonarr-port $config.sonarr.port]
        [settings-sonarr-apikey $sonarr_key]
        [languages-profiles ($profile | to json --raw)]
        [settings-general-serie_default_enabled true]
        [settings-general-serie_default_profile 1]
        [settings-general-movie_default_enabled true]
        [settings-general-movie_default_profile 1]
    ]
    | append ($config.subtitle_providers | each {|p| [settings-general-enabled_providers $p] })
    | append ($config.subtitle_languages | each {|l| [languages-enabled $l] })
    | each {|pair| [$pair.0 ($pair.1 | into string)] } | flatten
    let posted = request POST $"($base)/system/settings" {X-API-KEY: $key} $form application/x-www-form-urlencoded
    if $posted == null { return [(later "bazarr: settings update failed")] }

    let have = [$current.radarr.ip $current.radarr.port $current.sonarr.ip $current.sonarr.port] | each { into string }
    let want = [$config.radarr.host $config.radarr.port $config.sonarr.host $config.sonarr.port] | each { into string }
    # bazarr reads the profile only at start
    let restart = if $have == $want { [] } else {
        print "bazarr: corrected the Radarr/Sonarr addresses, restarting it to reload the profile"
        if (request POST $"($base)/system?action=restart" {X-API-KEY: $key}) == null { [(later "bazarr: restart failed")] } else { [] }
    }
    $restart | append (done $"bazarr: ($config.subtitle_languages | str join '+') subtitles from ($config.subtitle_providers | str join ', ')")
}

# an app answering something unexpected leaves its step pending, the others still run
def step [name: string, body: closure]: nothing -> list<record> {
    try { do $body } catch {|err| [(later $"($name): unexpected answer, ($err.msg)")] }
}

def main []: nothing -> nothing {
    let config = config-load
    let steps = [
        # prowlarr needs its own client for search-ui grabs
        (step prowlarr { servarr-wire $config prowlarr v1 category prowlarr })
        (step radarr { servarr-wire $config radarr v3 movieCategory radarr /data/media/movies })
        (step radarr { jellyfin-notify-wire $config radarr })
        (step sonarr { jellyfin-notify-wire $config sonarr })
        (step sonarr { servarr-wire $config sonarr v3 tvCategory sonarr /data/media/tv /data/media/anime })
        (step lidarr { servarr-wire $config lidarr v1 musicCategory lidarr /data/media/music })
        (step prowlarr { prowlarr-wire $config })
        (step jellyseerr { jellyseerr-wire $config })
        (step bazarr { bazarr-wire $config })
    ] | flatten
    if ($steps | any { $in.pending }) {
        print "some steps pending, retrying on next run"
    } else {
        print "media stack fully wired"
    }
}
