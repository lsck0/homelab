#!/usr/bin/env -S nu --no-config-file
# hermes agent e2e test on the free nous model (or the production config with ANTHROPIC_API_KEY), against a simulated
# lab: shims for vm, ssh, nc, lab-token, lab-pr and curl, a recording mock of paperless and firefly, a real sonarr and a
# bare copy of the repo standing in for github
#
# usage: hermes-agent.nu [scenario...]   (minecraft backup media bill repo telegram); KEEP=1 keeps the workdir

const SRC = path self ../../../..
const NET = "hermestest"
const SCENARIOS_DEFAULT = [minecraft backup media bill repo]
const AGENT_TIMEOUT_S = 900
const AGENT_TURNS_MAX = 60
const SONARR_PORT = 28989
const TELEGRAM_WINDOW_DEFAULT_S = 300
const HERMES = "nixosConfigurations.113-internal-hermes.config.services.hermes-agent"
const NAVIDROME = "src/instances/preconfigured/124-internal-navidrome/instance.nix"

def --wrapped quiet [...argv: string]: nothing -> record {
    do { ^$argv.0 ...($argv | skip 1) } | complete
}

def --wrapped nix-eval [...args: string]: nothing -> string {
    ^nix eval --no-warn-dirty ...$args
}

# a failure is recorded in HERMES_TEST_FAILURES, the run goes on to the next check
def check [ok: bool, pass: string, failure: string]: nothing -> nothing {
    if $ok { print $"  PASS  ($pass)" } else {
        print $"  FAIL  ($failure)"
        $"($failure)\n" | save --append $env.HERMES_TEST_FAILURES
    }
}

# fails once the attempts are spent
def wait-for [attempts: int, interval: duration, probe: closure] {
    for _ in 1..$attempts {
        if (do $probe) { return }
        sleep $interval
    }
    error make {msg: "gave up waiting"}
}

def env-build []: nothing -> path {
    let expr = $"
      let f = builtins.getFlake \"($SRC)\"; pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
        h = f.nixosConfigurations.\"113-internal-hermes\".config.services.hermes-agent;
      in pkgs.buildEnv { name = \"hermes-test-env\"; paths = [
        h.package pkgs.bashInteractive pkgs.coreutils
        pkgs.curl pkgs.jq pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.findutils pkgs.poppler-utils pkgs.python3 pkgs.procps
        pkgs.which pkgs.git pkgs.cacert pkgs.groff
        \(pkgs.writeTextDir \"share/hermes-test/skills\" \(builtins.concatStringsSep \"\\n\" h.settings.skills.external_dirs\)\) ]; }"
    let built = ^nix build --no-warn-dirty --no-link --print-out-paths --impure --expr $expr
    $built | str trim
}

def shim-write [dir: path, name: string, text: string]: nothing -> nothing {
    $text | save --force ($dir | path join $name)
    ^chmod +x ($dir | path join $name)
}

# the lab's commands as the agent calls them, logged to /work/log/calls.log
def shims-write [w: path, env_dir: path]: nothing -> nothing {
    let dir = $w | path join shims
    shim-write $dir _log "#!/bin/sh\nprintf '%s\\t%s\\n' \"$(date +%s)\" \"$*\" >> /work/log/calls.log\n"
    shim-write $dir vm r##'#!/bin/sh
/work/shims/_log vm "$@"
case "$1" in
  list|"") printf '104\trunning\t104-internal-nas\n131\trunning\t131-internal-paperless\n132\trunning\t132-internal-firefly\n214\trunning\t214-external-minecraft\n' ;;
  status) echo running ;;
  start) echo "vm-$2 up" ;;
  stop) echo "vm-$2 shutting down" ;;
  reboot) echo "vm-$2 rebooting" ;;
esac
'##
    shim-write $dir ssh (r##'#!/bin/bash
# coreutils date, not the agent's
export PATH="@ENVBIN@:$PATH"
args=("$@"); while [[ "${args[0]}" == -* ]]; do
  case "${args[0]}" in -o|-i|-p|-l|-F) args=("${args[@]:2}") ;; *) args=("${args[@]:1}") ;; esac
done
host=${args[0]#root@}; cmd="${args[*]:1}"
/work/shims/_log ssh "$host" "$cmd"
case "$host:$cmd" in
  10.200.0.214:*mc-modpack\ [a-z]*\ *)
    echo ">>> modpack set to ${cmd##*mc-modpack }, restarting server (first start downloads the pack)" ;;
  10.200.0.214:*mc-modpack*) printf 'current:\nTYPE=VANILLA\nVERSION=LATEST\nLEVEL=vanilla\n' ;;
  10.200.0.214:*podman\ logs*|10.200.0.214:*journalctl*) echo '[Server thread/INFO]: Done (41.237s)! For help, type "help"' ;;
  10.200.0.214:*mc-rcon*list*) echo "There are 0 of a max of 42069 players online:" ;;
  10.100.0.104:*nas-restore\ list*|10.100.0.104:*kopia*snapshot\ list*)
    [ -f /work/log/snapshots ] || for d in 3 2 1 0; do
      printf '%s  %s 02:00 CEST  files:%s\n' "$(printf 'snap%028d' "$d")" "$(date -d "$d days ago" +%F)" "8130$d"
    done > /work/log/snapshots
    cat /work/log/snapshots ;;
  10.100.0.104:*nas-restore\ now*)
    id=$(printf 'safe%028d' "$(date +%s)")
    printf '%s  %s CEST  files:81401\n' "$id" "$(date '+%F %H:%M')" >> /work/log/snapshots
    echo "Created snapshot with ID $id" ;;
  10.100.0.104:*nas-restore\ service*) echo ">>> done: /srv/nas/data/paperless restored" ;;
  10.100.0.104:*ls*data*) printf 'authelia\nfirefly\nforgejo\nminecraft\npaperless\nsonarr\n' ;;
  *) echo "ok" ;;
esac
'## | str replace "@ENVBIN@" $"($env_dir)/bin")
    shim-write $dir nc "#!/bin/sh\n/work/shims/_log nc \"$@\"; exit 0\n"
    shim-write $dir lab-token r##'#!/bin/sh
/work/shims/_log lab-token "$@"
[ -z "$1" ] && { ls /work/tokens | sed 's/\.token$//'; exit 0; }
cat "/work/tokens/$1.token"
'##
    # lab ips to the test backends
    shim-write $dir curl (r##'#!/bin/bash
out=()
for a in "$@"; do
  a=${a//http:\/\/10.100.0.121:8989/http://sonarr:8989}
  a=${a//http:\/\/10.100.0.131:8080/http://mock:8000/paperless}
  a=${a//http:\/\/10.100.0.132:8080/http://mock:8000/firefly}
  out+=("$a")
done
case "$*" in *10.100.0.*|*10.200.0.*) /work/shims/_log curl "$@" ;; esac
exec @CURL@ "${out[@]}"
'## | str replace "@CURL@" $"($env_dir)/bin/curl")
    shim-write $dir lab-pr r##'#!/bin/sh
/work/shims/_log lab-pr "$(git symbolic-ref --short HEAD)"
git push -q -u origin HEAD && echo "pull request: https://github.com/lsck0/homelab/pull/99"
'##
}

def mock-write [w: path]: nothing -> nothing {
    r#'import json, http.server, uuid
LOG = "/work/log/mock.jsonl"
class H(http.server.BaseHTTPRequestHandler):
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def _log(self, body):
        text = body.decode("utf-8", "replace")
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path,
                                "auth": self.headers.get("Authorization"), "body": text[:4000]}) + "\n")
    def do_GET(self):
        self._log(b""); p = self.path
        if p.startswith("/paperless/api/tasks"):
            return self._send([{"task_id": "t1", "status": "SUCCESS", "related_document": "42"}])
        if p.startswith("/paperless/api/documents/42"):
            return self._send({"id": 42, "title": "bill"})
        if p.startswith("/firefly/api/v1/accounts"):
            return self._send({"data": [{"id": "1", "type": "accounts", "attributes": {"name": "Girokonto", "type": "asset", "current_balance": "1234.56", "currency_code": "EUR", "active": True}}]})
        if p.startswith("/firefly/api/v1/about") or p == "/firefly/" or p.startswith("/firefly/api"):
            return self._send({"data": {"version": "6.3.0"}})
        return self._send({})
    def do_POST(self):
        body = self._body(); self._log(body); p = self.path
        if p.startswith("/paperless/api/documents/post_document"):
            return self._send(str(uuid.uuid4()))
        if p.startswith("/firefly/api/v1/transactions"):
            return self._send({"data": {"id": "77", "type": "transactions", "attributes": {"transactions": []}}})
        return self._send({})
    do_PATCH = do_PUT = do_POST
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever()
'# | save --force ($w | path join mock mock.py)
}

# the agent's home as vm-113 sets it up, its skills the store tree config.yaml names (env-build realises it); the model
# is the free nous tier unless ANTHROPIC_API_KEY is set
def home-write [w: path]: nothing -> nothing {
    let home = $w | path join home
    let settings = nix-eval --json $"($SRC)#($HERMES).settings" | from json
    let settings = if ($env.ANTHROPIC_API_KEY? | default "") != "" {
        $"ANTHROPIC_API_KEY=($env.ANTHROPIC_API_KEY)\n" | save --force ($home | path join .env)
        ^chmod 600 ($home | path join .env)
        print ">>> Model: production config (Anthropic)"
        $settings
    } else {
        print ">>> Model: Nous free tier (nous/welcome)"
        $settings | upsert model {provider: nous, default: nous/welcome}
    }
    $settings | upsert terminal.cwd /work/workspace | to yaml | save --force ($home | path join config.yaml)
    nix-eval --raw $"($SRC)#($HERMES).documents.\"AGENTS.md\"" | save --force ($w | path join workspace AGENTS.md)
    print ">>> config.yaml:"
    print (open --raw ($home | path join config.yaml) | lines | each { $"    ($in)" } | str join "\n")
}

# a bare copy stands in for github; the agent's git identity is vm-113's
def remote-write [w: path]: nothing -> string {
    ^git clone -q --bare --no-local ($SRC | path dirname) ($w | path join remote.git)
    let user = nix-eval --json $"($SRC)#nixosConfigurations.113-internal-hermes.config.programs.git.config" | from json
    | each { $in.user? } | compact | reduce --fold {} {|it, acc| $acc | merge $it }
    [
        "[user]" $"\tname = ($user.name)" $"\temail = ($user.email)"
        "[url \"/work/remote.git\"]" "\tinsteadOf = https://github.com/lsck0/homelab.git" "[safe]" "\tdirectory = *"
    ] | str join "\n" | $"($in)\n" | save --force ($w | path join home .gitconfig)
    ^chmod -R 777 ($w | path join remote.git)
    ^git -C ($w | path join remote.git) rev-parse master | str trim
}

def sonarr-start [w: path]: nothing -> nothing {
    print ">>> Starting Sonarr"
    mkdir ($w | path join sonarr) ($w | path join media tv) ($w | path join media anime)
    ^chmod -R 777 ($w | path join sonarr) ($w | path join media)
    let image = nix-eval --raw $"($SRC)#nixosConfigurations.121-internal-arr.config.virtualisation.oci-containers.containers.sonarr.image"
    (^docker run -d --name ht-sonarr --network $NET --network-alias sonarr -p $"127.0.0.1:($SONARR_PORT):8989"
        -e PUID=1000 -e PGID=1000 -v $"($w)/sonarr:/config" -v $"($w)/media:/data/media" $image) out> /dev/null
    let config = $w | path join sonarr config.xml
    wait-for 90 2sec { ($config | path exists) and (open --raw $config | str contains ApiKey) }
    let key = open --raw $config | parse --regex '<ApiKey>(?<key>[^<]+)' | get 0.key
    $key | save --force ($w | path join tokens sonarr-key.token)
    let api = $"http://127.0.0.1:($SONARR_PORT)/api/v3"
    wait-for 60 2sec { try { http get --headers [X-Api-Key $key] $"($api)/system/status" | ignore; true } catch { false } }
    for root in [/data/media/tv /data/media/anime] {
        http post --headers [X-Api-Key $key] --content-type application/json $"($api)/rootfolder" {path: $root} | ignore
    }
}

# the calls the agent made this scenario
def calls [w: path]: nothing -> list<string> {
    open --raw ($w | path join log calls.log) | lines | each { split row "\t" | skip 1 | str join "\t" }
}

def called [w: path, pattern: string]: nothing -> bool {
    calls $w | any { $in =~ $pattern }
}

def line-of [w: path, pattern: string]: nothing -> int {
    calls $w | enumerate | where { $in.item =~ $pattern } | get 0.index
}

def ask [w: path, env_dir: path, name: string, prompt: string, cache: path]: nothing -> nothing {
    print $">>> [($name)] owner: ($prompt)"
    "" | save --force ($w | path join log calls.log)
    "" | save --force ($w | path join log mock.jsonl)
    let uid = ^id -u
    let gid = ^id -g
    let user = $"($uid | str trim):($gid | str trim)"
    let out = $w | path join log $"($name).out"
    let ran = do {
        (^docker run --rm --user $user --network $NET -v /nix/store:/nix/store:ro -v $"($w):/work"
            -v $"($env_dir)/bin/bash:/bin/bash:ro" -w /work/workspace
            -e HOME=/work/home -e HERMES_HOME=/work/home -e HERMES_GUEST_ONBOARDING=1
            -e $"SSL_CERT_FILE=($env_dir)/etc/ssl/certs/ca-bundle.crt" -e $"PATH=/work/shims:($env_dir)/bin"
            alpine timeout $AGENT_TIMEOUT_S hermes chat -Q --yolo --max-turns $AGENT_TURNS_MAX -q $prompt)
    } | complete
    $"($ran.stdout)($ran.stderr)" | save --force $out
    identity-save $w $cache
    let transcript = open --raw $out
    if $transcript =~ "not logged into Nous Portal|not connected to any AI provider" {
        print "    ERROR: no model available"
        print ">>> Aborting: every retry extends the free-tier rate limit. Try later or set ANTHROPIC_API_KEY."
        cleanup $w
        exit 2
    }
    print $"    hermes: ($transcript | lines | where { not ($in | str starts-with session_id) } | last 8 | str join "\n    | ")"
    print "    lab calls:"
    print (calls $w | first 40 | each { $"      ($in)" } | str join "\n")
    ^cp ($w | path join log calls.log) ($w | path join log $"($name).calls")
    ^cp ($w | path join log mock.jsonl) ($w | path join log $"($name).mock")
}

# one guest identity is reused: minting is rate-limited
def identity-save [w: path, cache: path]: nothing -> nothing {
    let auth = $w | path join home auth.json
    if ($auth | path exists) and (ls $auth | get 0.size) > 0b { ^cp $auth ($cache | path join auth.json) }
}

def scenario-run [w: path, env_dir: path, cache: path, master: string, name: string]: nothing -> nothing {
    match $name {
        "minecraft" => {
            ask $w $env_dir minecraft "Start the cobblemon minecraft server with the Adrenaserver modpack please" $cache
            check (called $w 'ssh 10\.200\.0\.214 .*mc-modpack cobblemon .*adrenaserver') "minecraft: mc-modpack called with the server and the pack" "minecraft: mc-modpack not called with the server and the pack"
        }
        "backup" => {
            ask $w $env_dir backup "Paperless broke yesterday evening around 20:00. Restore it from the last backup before that." $cache
            let yesterday = (date now) - 1day | format date "%Y-%m-%d"
            let good = $"snap('' | fill -c '0' -w 27)1"
            check (called $w 'nas-restore (list|files)|kopia.*snapshot list') "backup: listed snapshots" "backup: did not list snapshots"
            check (called $w 'vm stop 131') "backup: stopped vm-131 first" "backup: did not stop vm-131"
            check (called $w 'nas-restore service paperless [^ ]+ --yes') "backup: restored paperless" "backup: did not run nas-restore service paperless"
            if (called $w 'vm stop 131') and (called $w 'nas-restore service paperless') {
                check ((line-of $w 'vm stop 131') < (line-of $w 'nas-restore service paperless')) "backup: stop before restore" "backup: restored while vm-131 running"
            }
            check (called $w 'vm start 131') "backup: started vm-131 again" "backup: did not start vm-131 again"
            check (called $w $"nas-restore service paperless \(($good)|($yesterday)\)\( |$\)") "backup: restored yesterday's 02:00 snapshot by id/date" "backup: wrong or age-based snapshot selection"
        }
        "media" => {
            ask $w $env_dir media "Hermes download new bleach ep" $cache
            let key = open --raw ($w | path join tokens sonarr-key.token)
            let api = $"http://127.0.0.1:($SONARR_PORT)/api/v3"
            let series = http get --headers [X-Api-Key $key] $"($api)/series"
            let bleach = $series | where { $in.title =~ '(?i)bleach' }
            check ($bleach | is-not-empty) "media: Bleach added to Sonarr" "media: Bleach not in Sonarr"
            print $"    series: ($series | each {|s| {title: $s.title?, type: $s.seriesType?, root: $s.rootFolderPath?, monitored: $s.monitored?} } | to json --raw)"
            check ($bleach | any { $in.seriesType == anime }) "media: added as anime" "media: not added as anime"
            let commands = http get --headers [X-Api-Key $key] $"($api)/command"
            print $"    commands: ($commands | get name | to json --raw)"
            check ($commands | any { $in.name in [EpisodeSearch SeriesSearch MissingEpisodeSearch] }) "media: search triggered" "media: no search triggered"
        }
        "bill" => {
            let pdf = $w | path join workspace rechnung-stadtwerke.pdf
            ".ps 14\nStadtwerke Duesseldorf AG\n.sp\nRechnung Nr. SW-2026-0815\n.br\nRechnungsdatum: 01.09.2026\n.br\nFaellig am: 15.09.2026\n.sp\nStrom August 2026 ........ 84,20 EUR\n.sp\nGesamtbetrag: 84,20 EUR\n"
            | ^$"($env_dir)/bin/groff" -Tpdf o> $pdf
            ask $w $env_dir bill "Here is a bill I got (attached: /work/workspace/rechnung-stadtwerke.pdf). File it in paperless and log it in firefly." $cache
            let mock = open --raw ($w | path join log mock.jsonl) | lines | where $it != "" | each { from json }
            check ($mock | any { $in.path | str starts-with /paperless/api/documents/post_document/ }) "bill: uploaded to Paperless" "bill: no Paperless upload"
            check ($mock | any { ($in.auth | default "") =~ "Token fake-paperless-token" }) "bill: Paperless token used" "bill: Paperless token missing"
            let tx = $mock | where { $in.method == POST and ($in.path | str starts-with /firefly/api/v1/transactions) } | last 1
            check ($tx | is-not-empty) "bill: Firefly transaction created" "bill: no Firefly transaction"
            if ($tx | is-not-empty) {
                let body = $tx.0.body | from json
                print $"    transaction: ($tx.0.body)"
                let split = $body.transactions.0
                check (($split.amount | into string) =~ '^84[.,]2') "bill: amount 84.20" "bill: wrong amount"
                check (($split.date | into string) | str starts-with 2026-09) "bill: date September 2026" "bill: wrong date"
                check ($split.type == withdrawal) "bill: withdrawal" "bill: not a withdrawal"
                check (($tx.0.auth | default "") =~ "Bearer fake-firefly-token") "bill: Firefly token used" "bill: Firefly token missing"
            }
        }
        "repo" => {
            ask $w $env_dir repo "Make Navidrome's on-demand idle time 1 hour in the homelab repo and open a PR for it." $cache
            let remote = $w | path join remote.git
            let branch = ^git -C $remote for-each-ref "--format=%(refname:short)" "refs/heads/hermes/*" | lines | get -o 0 | default ""
            check ($branch != "") $"repo: pushed ($branch)" "repo: no hermes/* branch pushed"
            check ((^git -C $remote rev-parse master | str trim) == $master) "repo: master untouched" "repo: master changed"
            check (called $w 'lab-pr hermes/') "repo: lab-pr opened the pull request" "repo: lab-pr not used"
            if $branch != "" {
                print (^git -C $remote diff $"master...($branch)" | lines | first 30 | each { $"      ($in)" } | str join "\n")
                check ((^git -C $remote diff --name-only $"master...($branch)" | str trim) == $NAVIDROME) $"repo: only ($NAVIDROME) changed" "repo: unexpected files changed"
                check ((^git -C $remote show $"($branch):($NAVIDROME)") =~ 'stopAfter *= "1h"') "repo: vm-124 stops after 1h idle" "repo: vm-124 idle.stopAfter not 1h"
                let subjects = ^git -C $remote log --format=%s $"master..($branch)" | lines
                check ($subjects | any { $in =~ '^[a-z]+(\([a-z0-9-]+\))?!?: ' }) "repo: conventional commit" "repo: commit message not conventional"
            }
        }
        "telegram" => { telegram-run $w $env_dir $cache }
        _ => { error make {msg: $"unknown scenario ($name)"} }
    }
}

# the live bot for a window, with a real telegram token
def telegram-run [w: path, env_dir: path, cache: path]: nothing -> nothing {
    let token = $env.TELEGRAM_BOT_TOKEN? | default ""
    let users = $env.TELEGRAM_ALLOWED_USERS? | default ""
    if $token == "" or $users == "" { error make {msg: "set TELEGRAM_BOT_TOKEN and TELEGRAM_ALLOWED_USERS"} }
    let window = $env.TELEGRAM_WINDOW? | default $TELEGRAM_WINDOW_DEFAULT_S | into int
    "" | save --force ($w | path join log calls.log)
    $"TELEGRAM_BOT_TOKEN=($token)\nTELEGRAM_ALLOWED_USERS=($users)\nTELEGRAM_HOME_CHANNEL=($users)\n" | save --append ($w | path join home .env)
    ^chmod 600 ($w | path join home .env)
    quiet docker rm -f ht-gateway | ignore
    let uid = ^id -u
    let gid = ^id -g
    let user = $"($uid | str trim):($gid | str trim)"
    (^docker run -d --name ht-gateway --user $user --network $NET -v /nix/store:/nix/store:ro -v $"($w):/work"
        -v $"($env_dir)/bin/bash:/bin/bash:ro" -w /work/workspace -e HOME=/work/home -e HERMES_HOME=/work/home
        -e HERMES_GUEST_ONBOARDING=1 -e $"SSL_CERT_FILE=($env_dir)/etc/ssl/certs/ca-bundle.crt"
        -e $"PATH=/work/shims:($env_dir)/bin" alpine hermes gateway) out> /dev/null
    let text = $"Homelab test: Hermes \(free Nous model, simulated lab\) is listening for ($window)s. Try: start minecraft with the Fabulously Optimized modpack"
    try { http post --max-time 20sec --content-type application/x-www-form-urlencoded $"https://api.telegram.org/bot($token)/sendMessage" [chat_id $users text $text] | ignore }
    print $">>> [telegram] gateway running for ($window)s: message the bot now"
    sleep ($window * 1sec)
    (quiet docker logs ht-gateway) | $"($in.stdout)($in.stderr)" | save --force ($w | path join log gateway.log)
    quiet docker rm -f ht-gateway | ignore
    identity-save $w $cache
    print "    lab calls:"
    print (calls $w | first 40 | each { $"      ($in)" } | str join "\n")
    let logs = glob ($w | path join home logs *.log) | append ($w | path join log gateway.log) | each { open --raw $in } | str join "\n"
    check ($logs =~ '(?i)telegram.*(connected|polling|started)') "telegram: gateway connected" "telegram: gateway did not connect"
    check ((calls $w) | is-not-empty) "telegram: owner's message drove lab actions" "telegram: no lab actions (no message sent in the window?)"
}

def cleanup [w: path]: nothing -> nothing {
    quiet docker rm -f ht-sonarr ht-mock ht-gateway | ignore
    quiet docker network rm $NET | ignore
    if ($env.KEEP? | default "0") == "1" {
        print $">>> KEEP=1: workdir ($w)"
        return
    }
    # the containers wrote as other users
    quiet docker run --rm -v $"($w):/w" alpine sh -c "rm -rf /w/*" | ignore
    rm --recursive --force $w
}

def main [...scenarios: string]: nothing -> nothing {
    let scenarios = if ($scenarios | is-empty) { $SCENARIOS_DEFAULT } else { $scenarios }
    let w = mktemp --directory --tmpdir hermes-test.XXXXXX
    $env.HERMES_TEST_FAILURES = mktemp --tmpdir hermes-test-failures.XXXXXX
    try {
        print ">>> Building Hermes (vm-113 package) and test tools"
        let env_dir = env-build
        for dir in [home workspace shims log tokens mock] { mkdir ($w | path join $dir) }
        "" | save --force ($w | path join home .env)
        ^chmod -R 777 $w
        home-write $w
        let cache = $env.XDG_CACHE_HOME? | default ($env.HOME | path join .cache) | path join homelab-hermes-test
        mkdir $cache
        ^chmod 700 $cache
        if ($cache | path join auth.json | path exists) { ^cp ($cache | path join auth.json) ($w | path join home auth.json) }
        shims-write $w $env_dir
        "fake-paperless-token" | save --force ($w | path join tokens paperless-key.token)
        "fake-firefly-token" | save --force ($w | path join tokens firefly-token.token)
        let master = remote-write $w
        mock-write $w
        quiet docker network rm $NET | ignore
        ^docker network create $NET out> /dev/null
        quiet docker rm -f ht-mock | ignore
        (^docker run -d --name ht-mock --network $NET --network-alias mock -v /nix/store:/nix/store:ro -v $"($w):/work"
            alpine $"($env_dir)/bin/python3" /work/mock/mock.py) out> /dev/null
        if "media" in $scenarios { sonarr-start $w }
        for name in $scenarios { scenario-run $w $env_dir $cache $master $name }
    } catch {|err|
        cleanup $w
        error make {msg: $err.msg}
    }
    cleanup $w
    print ""
    let failed = open --raw $env.HERMES_TEST_FAILURES | str trim | is-not-empty
    rm --force $env.HERMES_TEST_FAILURES
    if $failed {
        print ">>> SOME CHECKS FAILED (transcripts: KEEP=1)"
        exit 1
    }
    print ">>> ALL CHECKS PASSED"
}
