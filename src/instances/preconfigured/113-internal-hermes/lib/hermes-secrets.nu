#!/usr/bin/env -S nu --no-config-file
# fill hermes (vm-113) secrets, then run ./sync.nu

const HERMES_DIR = path self | path dirname | path dirname
const ROOT = $HERMES_DIR | path dirname | path dirname | path dirname | path dirname
const SRC = $ROOT | path join src
use ../../../../scripts/lib/tools.nu [die tools-require warn]
use ../../../../scripts/lib/secrets.nu [secrets-age-key-ready secrets-get secrets-set]

const HERMES_ID = "113"
const RULESET_NAME = "protect-master"
# the manifest flow waits this long for the owner to create the app in the browser
const APP_CREATE_TIMEOUT_S = 900
# then up to 15 minutes for the owner to install it on the repo
const APP_INSTALL_ATTEMPTS = 180
const APP_INSTALL_RETRY = 5sec
# github's built-in repository role "admin"; its id is fixed by the rulesets api, not looked up per repo
const REPOSITORY_ROLE_ADMIN_ID = 5
const GITHUB_API = "https://api.github.com"
# nu has no http listener: the manifest flow's local page and its redirect target are python's standard server
const MANIFEST_FLOW = r#'
import html, http.server, json, secrets, subprocess, sys, time, urllib.parse, urllib.request
repo, out, timeout_s = sys.argv[1], sys.argv[2], int(sys.argv[3])
state = secrets.token_urlsafe(24)
manifest = {
    "name": f"{repo.replace('/', '-')}-hermes",
    "url": f"https://github.com/{repo}",
    "hook_attributes": {"url": f"https://github.com/{repo}", "active": False},
    "public": False,
    "default_permissions": {"contents": "write", "pull_requests": "write", "metadata": "read"},
    "default_events": [],
}
done = False
class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body, location=None):
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        global done
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            return self.reply(200, f"""<form method="post" action="https://github.com/settings/apps/new?state={state}">
<input type="hidden" name="manifest" value="{html.escape(json.dumps(manifest))}"></form>
<script>document.forms[0].submit()</script>""")
        if url.path != "/created" or query.get("state") != [state] or "code" not in query:
            return self.reply(400, "unexpected request")
        request = urllib.request.Request(f"https://api.github.com/app-manifests/{query['code'][0]}/conversions",
                                         method="POST", headers={"Accept": "application/vnd.github+json"})
        app = json.load(urllib.request.urlopen(request))
        with open(out, "w") as f:
            json.dump({"id": app["id"], "slug": app["slug"], "pem": app["pem"]}, f)
        done = True
        self.reply(302, "", f"https://github.com/apps/{app['slug']}/installations/new")
    def log_message(self, *args): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
base = f"http://127.0.0.1:{server.server_address[1]}"
manifest["redirect_url"] = f"{base}/created"
print(f">>> Open {base}/ , create the app, then install it on {repo} only", flush=True)
subprocess.run(["xdg-open", f"{base}/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
deadline = time.monotonic() + timeout_s
while not done:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        sys.exit(f"no app created within {timeout_s} s; rerun to try again")
    # one request at a time, never past the deadline
    server.timeout = remaining
    server.handle_request()
'#

# a secret not set yet reads as empty
def current [name: string]: nothing -> string {
    try { secrets-get $SRC $name } catch { "" }
}

# --force regenerates the ssh key and the github app, and asks for the prompted secrets again
def main [--force]: nothing -> nothing {
    tools-require sops ssh-keygen gh python3 openssl nix
    secrets-age-key-ready ($ROOT | path join secrets age.txt)
    let site = open ($SRC | path join generated site.json)
    let repo = $site.repo
    let pub = $SRC | path join secrets keys hermes.pub
    let app_json = $HERMES_DIR | path join lib github-app.json
    let tmp = mktemp --directory

    # the generated private keys pass through $tmp: it goes on every way out, an error included
    let token = try {
        if (current hermes-ssh-key) == "" or $force or not ($pub | path exists) {
            ^ssh-keygen -q -t ed25519 -N "" -C "hermes@vm-113" -f ($tmp | path join lab)
            secrets-set $SRC hermes-ssh-key (open --raw ($tmp | path join lab))
            rm --force ($tmp | path join lab)
            # hermes may log in from its own vm only
            let ip = ^nix eval --raw --no-warn-dirty $"($SRC)#lab.inventory.\"($HERMES_ID)\".ip"
            $"from=\"($ip)\" (open --raw ($tmp | path join lab.pub) | str trim)\n" | save --force $pub
            ^git -C $ROOT add $pub
            print ">>> hermes-ssh-key generated, public key in src/secrets/keys/hermes.pub"
        } else {
            print ">>> hermes-ssh-key already set"
        }

        if (current hermes-github-app-key) == "" or not ($app_json | path exists) or $force {
            # manifest flow: a local page posts the manifest to github, the owner confirms there
            let created = $tmp | path join app.json
            ^python3 -c $MANIFEST_FLOW $repo $created ($APP_CREATE_TIMEOUT_S | into string)
            let app = open $created
            secrets-set $SRC hermes-github-app-key $app.pem
            rm --force $created
            {id: $app.id, slug: $app.slug} | to json --indent 2 | $"($in)\n" | save --force $app_json
            ^git -C $ROOT add $app_json
            print $">>> GitHub App ($app.slug) created"
        }

        let app = open $app_json
        let pem = $tmp | path join app.pem
        ^install -m 600 /dev/null $pem
        $"(current hermes-github-app-key)\n" | save --append $pem
        let token_script = $HERMES_DIR | path join lib github-app-token.nu
        mut token = ""
        for attempt in 1..$APP_INSTALL_ATTEMPTS {
            let got = do { ^nu --no-config-file $token_script ($app.id | into string) $pem $repo } | complete
            if $got.exit_code == 0 {
                $token = $got.stdout | str trim
                break
            }
            if $attempt == 1 { print $">>> waiting for the app to be installed on ($repo): https://github.com/apps/($app.slug)/installations/new" }
            sleep $APP_INSTALL_RETRY
        }
        $token
    } catch {|e|
        rm --recursive --force $tmp
        error make $e
    }
    rm --recursive --force $tmp
    if $token == "" { die $"app not installed on ($repo)" }
    let selection = http get --headers {Authorization: $"Bearer ($token)"} $"($GITHUB_API)/installation/repositories"
        | get repositories.full_name | str join " "
    if $selection != $repo { warn $"the app can reach ($selection); limit its installation to ($repo)" }
    print $">>> GitHub App installed on ($repo)"

    # master: only repo admins may update or delete
    let ruleset = {
        name: $RULESET_NAME, target: branch, enforcement: active
        conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}}
        rules: [{type: update} {type: deletion} {type: non_fast_forward}]
        bypass_actors: [{actor_id: $REPOSITORY_ROLE_ADMIN_ID, actor_type: RepositoryRole, bypass_mode: always}]
    } | to json
    let rulesets = ^gh api $"repos/($repo)/rulesets"
    let existing = $rulesets | from json | where name == $RULESET_NAME | get --optional 0.id
    let applied = if $existing != null {
        $ruleset | do { ^gh api -X PUT $"repos/($repo)/rulesets/($existing)" --input - } | complete
    } else {
        $ruleset | do { ^gh api -X POST $"repos/($repo)/rulesets" --input - } | complete
    }
    if $applied.exit_code != 0 { die $"ruleset ($RULESET_NAME) not applied: ($applied.stderr | str trim)" }
    print $">>> ruleset ($RULESET_NAME) active"

    for prompted in [[name question]; [telegram-bot-token "Telegram bot token (from @BotFather)"] [telegram-chat-id "Your Telegram user id (numeric)"]] {
        if (current $prompted.name) != "" and not $force {
            print $">>> ($prompted.name) already set"
            continue
        }
        if (is-terminal --stdin) == false {
            print $">>> ($prompted.name) missing: run this script in a terminal to enter it"
            continue
        }
        let value = input --suppress-output $"($prompted.question): "
        print ""
        if $value == "" { die $"($prompted.name) must not be empty." }
        secrets-set $SRC $prompted.name $value
        print $">>> ($prompted.name) saved"
    }

    print ">>> Done. Run ./sync.nu to deploy Hermes."
}
