#!/usr/bin/env -S nu --no-config-file
# lab-wide: the media stack of 120, 121, 122 and 123, run by hand against the real containers (docker)
#
# The apps run from the images their NixOS configs pin, the setup units' own scripts wire them (podman becomes docker,
# lab paths become the workdir), and arr-wire, built for vm-121, runs on the test network until it converges.
# env: KEEP=1 leaves the containers and the workdir for a look afterwards

const SRC = path self | path dirname | path dirname
const SELF = path self
const NETWORK = "mediatest"
const SUBNET = "172.30.99.0/24"
# container prefix; the network aliases stay plain
const PREFIX = "mt-"
const APPS = [qbittorrent prowlarr radarr sonarr lidarr jellyfin jellyseerr bazarr janitorr-stats janitorr]
const SHELL_PACKAGES = [bash curl jq yq-go gnused gnugrep coreutils openssl findutils python3 nushell]
# the apps answer their apis a few seconds after start; arr-wire runs every 10 minutes in the lab
const WIRE_RUNS_MAX = 12
const WIRE_RETRY = 10sec
const WIRE_ENV_KEYS = '^(INDEXERS|RADARR_PUBLIC_URL|SONARR_PUBLIC_URL|JELLYSEERR_ADMIN_EMAIL|TOR_HOST|TOR_PORT)$'
# janitorr runs its first cycle within a minute and a half of start; prowlarr pushes indexers within a minute
const JANITORR_WAIT_S = 120
const INDEXER_SYNC_WAIT_S = 60
const JANITORR_CYCLE = "Deleting Movies and updating Leaving Soon"
const QBIT_PBKDF2_ROUNDS = 100000

def nix-eval [host: string, attr: string]: nothing -> string {
    ^nix eval --no-warn-dirty --raw $"($SRC)#nixosConfigurations.($host).config.($attr)"
}

def image [host: string, container: string]: nothing -> string {
    nix-eval $host $"virtualisation.oci-containers.containers.($container).image"
}

def --wrapped docker-quiet [...args: string]: nothing -> nothing { do { ^docker ...$args } | complete | ignore }

def main []: nothing -> nothing {
    # same tool versions as the lab
    if ($env.MEDIA_TEST_SHELL? | is-empty) {
        let packages = $SHELL_PACKAGES | each { $"nixpkgs#($in)" }
        exec nix shell --inputs-from $SRC ...$packages -c env MEDIA_TEST_SHELL=1 nu --no-config-file $SELF
    }
    let w = mktemp --directory --tmpdir media-stack.XXXXXX
    let keep = ($env.KEEP? | default "0") == "1"
    mut failed = false
    let check = {|description: string, test: closure|
        let passed = try { do $test } catch { false }
        print $"  (if $passed { 'PASS' } else { 'FAIL' })  ($description)"
        $passed
    }

    # podman on the vms, docker here
    mkdir ($w | path join bin) ($w | path join tokens) ($w | path join run)
    "#!/bin/sh\nexec docker \"$@\"\n" | save ($w | path join bin podman)
    ^chmod +x ($w | path join bin podman)
    $env.PATH = $env.PATH | prepend ($w | path join bin)

    # the lab's token layout (modules/tokens): each producer writes its own dir, tokens/<name>.token are links into
    # them, so a setup unit that wrote through a link instead of its own dir breaks here as it would in the lab
    let producers_json = ^nix eval --no-warn-dirty --json $"($SRC)#nixosConfigurations.113-internal-hermes.config.homelab.tokens.producers"
    let producers = $producers_json | from json
    for producer in ($producers | transpose name id) {
        mkdir ($w | path join tokens.d $"vm-($producer.id)")
        ^ln -sfn ($w | path join tokens.d $"vm-($producer.id)" $"($producer.name).token") ($w | path join tokens $"($producer.name).token")
    }
    let tok = [$"s#/var/lib/lab-tokens.d#($w)/tokens.d#g; s#/var/lib/lab-tokens#($w)/tokens#g"]

    # a setup unit's own script, its lab paths edited by sed expressions, run with the unit's RuntimeDirectory
    let run_unit = {|host: string, unit: string, edits: list<string>|
        mkdir ($w | path join scripts) ($w | path join run $unit)
        # realise the store paths the script references
        ^nix build --no-warn-dirty --no-link $"($SRC)#nixosConfigurations.($host).config.systemd.units.\"($unit).service\".unit"
        let script = $w | path join scripts $"($unit).sh"
        let body = nix-eval $host $"systemd.services.\"($unit)\".script"
        $"set -e\n($body)" | save --force $script
        for edit in $edits { ^sed -i $edit $script }
        print $">>> ($unit)"
        with-env {RUNTIME_DIRECTORY: ($w | path join run $unit)} { ^bash $script }
    }

    print $">>> workdir ($w)"
    for app in $APPS { docker-quiet rm -f $"($PREFIX)($app)" }
    docker-quiet network rm $NETWORK
    ^docker network create --subnet $SUBNET $NETWORK out> /dev/null
    for dir in [movies tv anime music leaving-soon] { mkdir ($w | path join media $dir) }
    mkdir ($w | path join torrents)
    ^chmod -R 777 ($w | path join media) ($w | path join torrents) ($w | path join tokens) ($w | path join tokens.d)

    let run_app = {|name: string, img: string, port: string, args: list<string>|
        mkdir ($w | path join $name)
        ^chmod 777 ($w | path join $name)
        docker-quiet rm -f $"($PREFIX)($name)"
        (^docker run -d --name $"($PREFIX)($name)" --network $NETWORK --network-alias $name
            -p $"127.0.0.1:($port)" -e PUID=1000 -e PGID=1000 -e TZ=Europe/Berlin ...$args $img) out> /dev/null
        print $"    started ($name) \(($img)\)"
    }
    print ">>> Starting containers (images from the NixOS configs)"
    let data = [-v $"($w)/media:/data/media" -v $"($w)/torrents:/data/torrents"]
    do $run_app qbittorrent (image 120-internal-qbittorrent qbittorrent) 18080:8080 [-e WEBUI_PORT=8080 -v $"($w)/qbittorrent:/config" -v $"($w)/torrents:/data/torrents"]
    do $run_app prowlarr (image 121-internal-arr prowlarr) 19696:9696 ([-v $"($w)/prowlarr:/config"] ++ $data)
    do $run_app radarr (image 121-internal-arr radarr) 17878:7878 ([-v $"($w)/radarr:/config"] ++ $data)
    do $run_app sonarr (image 121-internal-arr sonarr) 18989:8989 ([-v $"($w)/sonarr:/config"] ++ $data)
    do $run_app lidarr (image 121-internal-arr lidarr) 18686:8686 ([-v $"($w)/lidarr:/config"] ++ $data)
    mkdir ($w | path join jellyfin config) ($w | path join jellyfin cache)
    do $run_app jellyfin (image 122-internal-jellyfin jellyfin) 18096:8096 [-v $"($w)/jellyfin/config:/config" -v $"($w)/jellyfin/cache:/cache" -v $"($w)/media:/data/media:ro"]
    do $run_app jellyseerr (image 123-internal-jellyseerr jellyseerr) 15055:5055 [--init -e PORT=5055 -v $"($w)/jellyseerr:/app/config"]
    do $run_app bazarr (image 121-internal-arr bazarr) 16767:6767 [-v $"($w)/bazarr:/config" -v $"($w)/media:/data/media"]

    # -------------------------------------------------------------------------
    # PER-VM SETUP UNITS
    # -------------------------------------------------------------------------
    do $run_unit 120-internal-qbittorrent qbittorrent-disable-auth [
        $"s#/var/lib/qbittorrent#($w)/qbittorrent#g"
        $"s#systemctl stop podman-qbittorrent.service#docker stop ($PREFIX)qbittorrent#"
        $"s#systemctl start podman-qbittorrent.service#docker start ($PREFIX)qbittorrent#"
    ]
    # whitelist the test subnet, not the lab vms
    ^nix build --no-warn-dirty --no-link $"($SRC)#nixosConfigurations.120-internal-qbittorrent.config.systemd.units.\"qbittorrent-settings.service\".unit"
    let qprefs = nix-eval 120-internal-qbittorrent systemd.services.qbittorrent-settings.script | parse --regex '(?<p>/nix/store/\S*-qbittorrent-prefs\.json)' | get 0.p
    open $qprefs | upsert bypass_auth_subnet_whitelist $SUBNET | to json | save --force ($w | path join qbittorrent-prefs.json)
    do $run_unit 120-internal-qbittorrent qbittorrent-settings ($tok ++ [
        $"s#($qprefs)#($w)/qbittorrent-prefs.json#"
        $"s#podman exec \\\(-i \\\)\\?qbittorrent#podman exec \\1($PREFIX)qbittorrent#g"
    ])
    for name in [prowlarr radarr sonarr lidarr bazarr] {
        do $run_unit 121-internal-arr $"($name)-setup" ($tok ++ [
            $"s#/var/lib/($name)#($w)/($name)#g"
            $"s#systemctl stop podman-($name).service#docker stop ($PREFIX)($name)#"
            $"s#systemctl start podman-($name).service#docker start ($PREFIX)($name)#"
        ])
    }
    let jf = $tok ++ ["s#http://127.0.0.1:80#http://127.0.0.1:18096#g"]
    do $run_unit 122-internal-jellyfin jellyfin-setup $jf
    do $run_unit 123-internal-jellyseerr jellyseerr-token ($tok ++ [$"s#/var/lib/jellyseerr#($w)/jellyseerr#g"])

    # -------------------------------------------------------------------------
    # JELLYFIN SETUP UNDER A RESTART (the readiness contract, no fixed waits)
    # -------------------------------------------------------------------------
    print ">>> jellyfin restarted, setup at once: it waits for ready instead of failing"
    ^docker restart $"($PREFIX)jellyfin" out> /dev/null
    if not (do $check "jellyfin-setup right after a restart" { do $run_unit 122-internal-jellyfin jellyfin-setup $jf; true }) { $failed = true }
    let third = do { do $run_unit 122-internal-jellyfin jellyfin-setup $jf } | complete
    print $third.stdout $third.stderr
    if ($"($third.stdout)($third.stderr)" =~ "restarting jellyfin|created|enabled|revoked|exported") {
        print "  FAIL  jellyfin-setup third run changed something"
        $failed = true
    } else {
        print "  PASS  jellyfin-setup third run is a no-op"
    }
    print $">>> Exported tokens: (ls ($w | path join tokens) | get name | path basename | str join ' ')"

    # -------------------------------------------------------------------------
    # ARR-WIRE (THE REAL SCRIPT BUILT FOR VM-121, RUN ON THE TEST NETWORK)
    # -------------------------------------------------------------------------
    ^nix build --no-warn-dirty --no-link $"($SRC)#nixosConfigurations.121-internal-arr.config.systemd.services.arr-wire.serviceConfig.ExecStart"
    let wire = nix-eval 121-internal-arr systemd.services.arr-wire.serviceConfig.ExecStart
    # the unit's own environment, addresses replaced by the test network's below
    let wire_env_json = ^nix eval --no-warn-dirty --json $"($SRC)#nixosConfigurations.121-internal-arr.config.systemd.services.arr-wire.environment"
    let wire_env = $wire_env_json | from json
        | transpose key value | where key =~ $WIRE_ENV_KEYS | each { [-e $"($in.key)=($in.value)"] } | flatten
    let test_env = {
        TOKEN_DIR: ($w | path join tokens), QBIT_HOST: qbittorrent, QBIT_PORT: 8080, PROWLARR_HOST: prowlarr, PROWLARR_PORT: 9696
        RADARR_HOST: radarr, RADARR_PORT: 7878, SONARR_HOST: sonarr, SONARR_PORT: 8989, LIDARR_HOST: lidarr, LIDARR_PORT: 8686
        JELLYFIN_HOST: jellyfin, JELLYFIN_PORT: 8096, JELLYSEERR_URL: "http://jellyseerr:5055", BAZARR_URL: "http://bazarr:6767"
    } | transpose key value | each { [-e $"($in.key)=($in.value)"] } | flatten
    let arr_wire = {||
        let r = do { ^docker run --rm --network $NETWORK -v /nix/store:/nix/store:ro -v $"($w):($w)" ...$wire_env ...$test_env alpine $wire } | complete
        $"($r.stdout)($r.stderr)"
    }

    print ">>> arr-wire until converged (it retries on a timer in the lab)"
    mut converged = false
    for run in 1..$WIRE_RUNS_MAX {
        print $"--- run ($run)"
        let out = do $arr_wire
        print $out
        if ($out | str contains "media stack fully wired") {
            $converged = true
            break
        }
        sleep $WIRE_RETRY
    }

    print ">>> Checks"
    print $"  (if $converged { 'PASS  arr-wire converged' } else { 'FAIL  arr-wire did not converge' })"
    if not $converged { $failed = true }

    let key = {|name: string| open --raw ($w | path join tokens $"($name).token") | str trim }
    let api = {|url: string, api_key: string| http get --headers {X-Api-Key: $api_key} $url }
    let api_post = {|url: string, api_key: string, body: any| http post --headers {X-Api-Key: $api_key} --content-type application/json $url $body }
    mut results = []
    for spec in [[name port version folder]; [radarr 17878 v3 /data/media/movies] [sonarr 18989 v3 /data/media/anime] [lidarr 18686 v1 /data/media/music]] {
        let base = $"http://127.0.0.1:($spec.port)/api/($spec.version)"
        let k = do $key $"($spec.name)-key"
        $results = $results | append (do $check $"($spec.name): qBittorrent download client connects" {
            let client = do $api $"($base)/downloadclient" $k | where implementation == QBittorrent | first
            do $api_post $"($base)/downloadclient/test" $k $client | ignore
            true
        })
        $results = $results | append (do $check $"($spec.name): root folder ($spec.folder)" {
            do $api $"($base)/rootfolder" $k | any { $in.path == $spec.folder and $in.accessible }
        })
    }
    $results = $results | append (do $check "sonarr: root folder /data/media/tv" {
        do $api http://127.0.0.1:18989/api/v3/rootfolder (do $key sonarr-key) | any { $in.path == "/data/media/tv" }
    })

    let pk = do $key prowlarr-key
    let prowlarr = "http://127.0.0.1:19696/api/v1"
    $results = $results | append (do $check "prowlarr: 4 apps connected" { (do $api $"($prowlarr)/applications" $pk | length) == 4 })
    for app in (do $api $"($prowlarr)/applications" $pk) {
        $results = $results | append (do $check $"prowlarr: app ($app.name) connection test" {
            do $api_post $"($prowlarr)/applications/test" $pk (do $api $"($prowlarr)/applications/($app.id)" $pk) | ignore
            true
        })
    }
    $results = $results | append (do $check "prowlarr: qBittorrent download client present (so Grab works)" {
        do $api $"($prowlarr)/downloadclient" $pk | any { $in.implementation == QBittorrent and $in.enable }
    })
    $results = $results | append (do $check "prowlarr: Tor indexer proxy present" {
        do $api $"($prowlarr)/indexerproxy" $pk | any { $in.implementation == Socks5 }
    })
    $results = $results | append (do $check "prowlarr: every indexer carries the tor tag" {
        let tor = do $api $"($prowlarr)/tag" $pk | where label == tor | get 0.id
        do $api $"($prowlarr)/indexer" $pk | all { $tor in ($in.tags? | default []) }
    })
    print $"  info  prowlarr indexers: (do $api $"($prowlarr)/indexer" $pk | get definitionName | str join ', ')"
    $results = $results | append (do $check "prowlarr: nyaasi (anime) indexer present" {
        do $api $"($prowlarr)/indexer" $pk | any { $in.definitionName == nyaasi }
    })
    $results = $results | append (do $check "radarr: indexers synced from Prowlarr" {
        let rk = do $key radarr-key
        seq 1 $INDEXER_SYNC_WAIT_S | any {|_|
            let synced = (try { do $api http://127.0.0.1:17878/api/v3/indexer $rk | length } catch { 0 }) > 0
            if not $synced { sleep 1sec }
            $synced
        }
    })

    let jk = do $key jellyseerr-key
    $results = $results | append (do $check "jellyseerr: initialized" { (http get http://127.0.0.1:15055/api/v1/settings/public).initialized })
    for arr in [radarr sonarr] {
        $results = $results | append (do $check $"jellyseerr: ($arr) connection test" {
            let body = do $api $"http://127.0.0.1:15055/api/v1/settings/($arr)" $jk | first
            do $api_post $"http://127.0.0.1:15055/api/v1/settings/($arr)/test" $jk $body | ignore
            true
        })
    }
    $results = $results | append (do $check "jellyseerr: sonarr anime folder set" {
        (do $api http://127.0.0.1:15055/api/v1/settings/sonarr $jk | first).activeAnimeDirectory == "/data/media/anime"
    })
    $results = $results | append (do $check "bazarr: radarr + sonarr enabled" {
        let general = http get --headers {X-API-KEY: (do $key bazarr-key)} http://127.0.0.1:16767/api/system/settings | get general
        $general.use_radarr and $general.use_sonarr
    })
    # whitelisted logins always succeed, so the stored hash is what proves the password
    $results = $results | append (do $check "qbittorrent: WebUI password is the generated one" {
        let stored = open --raw ($w | path join qbittorrent qBittorrent qBittorrent.conf) | parse --regex 'Password_PBKDF2="@ByteArray\((?<salt>[^:]+):(?<key>[^)]+)\)"' | first
        let derived = ^openssl kdf -keylen (($stored.key | decode base64 | bytes length) | into string) -kdfopt digest:SHA512 -kdfopt $"pass:(do $key qbittorrent-pass)" -kdfopt $"hexsalt:($stored.salt | decode base64 | encode hex)" -kdfopt $"iter:($QBIT_PBKDF2_ROUNDS)" PBKDF2
        ($derived | str trim | str replace --all ":" "" | str downcase) == ($stored.key | decode base64 | encode hex | str downcase)
    })

    let jellyfin = {|path: string| http get --headers {Authorization: $"MediaBrowser Token=\"(do $key jellyfin-key-hermes)\""} $"http://127.0.0.1:18096($path)" }
    $results = $results | append (do $check "jellyfin: Movies/Shows/Anime libraries" {
        let names = do $jellyfin /Library/VirtualFolders | get Name
        [Movies Shows Anime] | all { $in in $names }
    })
    $results = $results | append (do $check "jellyfin: janitorr user can delete and is no admin" {
        do $jellyfin /Users | any { $in.Name == janitorr and $in.Policy.EnableContentDeletion and not $in.Policy.IsAdministrator }
    })
    $results = $results | append (do $check "jellyfin: one api key per consumer, the shared one gone" {
        let apps = do $jellyfin /Auth/Keys | get Items.AppName
        "homelab" not-in $apps and ([homelab-homepage homelab-hermes homelab-arr homelab-janitorr] | all { $in in $apps })
    })
    $results = $results | append (do $check "jellyfin: only the sso plugin authenticates" {
        let plugins = do $jellyfin /Plugins | get Name
        ($plugins | any { $in =~ SSO }) and not ($plugins | any { $in =~ LDAP })
    })
    for token in [jellyfin-key-homepage jellyfin-admin-pass janitorr-pass] {
        $results = $results | append (do $check $"tokens: ($token) is a link into vm-122's own dir" {
            let link = $w | path join tokens $"($token).token"
            let own = $w | path join tokens.d vm-122 $"($token).token"
            ($link | path type) == symlink and ($own | path type) == file
        })
    }

    print ">>> Idempotence: second arr-wire run must change nothing"
    let second = do $arr_wire
    print $second
    let changes = $second | lines | where { not ($in | str contains "unreachable, skipped") } | any { $in =~ "added|connected|initialised|failed" }
    print $"  (if $changes { 'FAIL  arr-wire second run made changes' } else { 'PASS  arr-wire second run is a no-op' })"
    if $changes { $failed = true }

    # -------------------------------------------------------------------------
    # JANITORR
    # -------------------------------------------------------------------------
    print ">>> Janitorr with the config NixOS renders"
    mkdir ($w | path join janitorr logs) ($w | path join janitorr stats)
    ^chmod -R 777 ($w | path join janitorr)
    do $run_unit 122-internal-jellyfin janitorr-config ($tok ++ [$"s#/var/lib/janitorr#($w)/janitorr#g" "s#chown 1000:1000#true#"])
    # the lab's addresses (the collected inventory and routes, modules/lab) to the test network's names
    let url_of = {|route: string|
        ^nix eval --no-warn-dirty --raw $"($SRC)#lab" --apply $"l: let r = l.routes.internal.($route); in \"http://${l.inventory.${toString r.vmid}.ip}:${toString r.port}\""
    }
    let renames = [[from to]; [(do $url_of sonarr) "http://sonarr:8989"] [(do $url_of radarr) "http://radarr:7878"]
        [(do $url_of jellyfin) "http://jellyfin:8096"] [(do $url_of jellyseerr) "http://jellyseerr:5055"] ["http://127.0.0.1:8081" "http://janitorr-stats:8081"]]
    for file in [application.yml stats.yml] {
        let path = $w | path join janitorr $file
        $renames | reduce --fold (open --raw $path) {|r, text| $text | str replace --all $r.from $r.to } | save --force $path
        ^chmod 644 $path
    }
    docker-quiet rm -f $"($PREFIX)janitorr-stats" $"($PREFIX)janitorr"
    (^docker run -d --name $"($PREFIX)janitorr-stats" --network $NETWORK --network-alias janitorr-stats
        -v $"($w)/janitorr/stats.yml:/work/config/application.yml:ro" -v $"($w)/janitorr/stats:/data"
        (image 122-internal-jellyfin janitorr-stats)) out> /dev/null
    (^docker run -d --name $"($PREFIX)janitorr" --network $NETWORK --user 1000:1000 -e SERVER_PORT=8082 --memory=512m
        -v $"($w)/janitorr/application.yml:/config/application.yml:ro" -v $"($w)/janitorr/logs:/logs" ...$data
        (image 122-internal-jellyfin janitorr)) out> /dev/null
    let logs_of = {|container: string| do { ^docker logs $container } | complete | $"($in.stdout)($in.stderr)" }
    for _ in 1..$JANITORR_WAIT_S {
        if (do $logs_of $"($PREFIX)janitorr" | str contains $JANITORR_CYCLE) { break }
        sleep 1sec
    }
    let running = {|container: string| (^docker inspect -f '{{.State.Running}}' $container | str trim) == "true" }
    $results = $results | append (do $check "janitorr-stats running" { do $running $"($PREFIX)janitorr-stats" })
    $results = $results | append (do $check "janitorr running" { do $running $"($PREFIX)janitorr" })
    $results = $results | append (do $check "janitorr ran a cleanup cycle" { do $logs_of $"($PREFIX)janitorr" | str contains $JANITORR_CYCLE })
    let levels = {|container: string| do $logs_of $container | lines | where $it =~ '^[0-9T:., -]+Z? +(ERROR|WARN)' }
    let noisy = (do $levels $"($PREFIX)janitorr") ++ (do $levels $"($PREFIX)janitorr-stats")
    if ($noisy | is-not-empty) {
        print "  FAIL  janitorr / janitorr-stats logged ERROR or WARN:"
        $noisy | first 10 | each { print $in } | ignore
        $failed = true
    } else {
        print "  PASS  janitorr + janitorr-stats: no ERROR/WARN"
    }

    if not $keep {
        for app in $APPS { docker-quiet rm -f $"($PREFIX)($app)" }
        docker-quiet network rm $NETWORK
        # the containers wrote as their own users: a container removes what plain rm may not
        docker-quiet run --rm -v $"($w):/w" alpine sh -c "rm -rf /w/*"
        rm --recursive --force $w
    } else {
        print $">>> KEEP=1: containers left running, workdir ($w)"
    }
    print ""
    if $failed or ($results | any { not $in }) {
        print ">>> SOME CHECKS FAILED"
        exit 1
    }
    print ">>> ALL CHECKS PASSED"
}
