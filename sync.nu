#!/usr/bin/env -S nu --no-config-file
# sync the entire lab: apply terraform, deploy nixos, commit the generation
#
# Trust: the Proxmox host's ssh key is pinned in src/generated/known_hosts by src/scripts/init.nu --pin, after the owner
# compared its fingerprint on the console. Every guest's host key is read through that pinned channel from the
# hypervisor's own view of the guest (qemu guest agent, pct pull) and written to src/generated/known_hosts, and every
# ssh of the run checks it strictly. Nothing secret goes to an address whose key the network vouched for. Each guest
# gets only its own age key (secrets-sync.nu); the admin key never leaves this machine.
#
# The run is a child of this script, which tees its output to the log and cleans up after it however it ended: the
# on-demand reaper resumed, the run's temp dir removed. An ssh-agent the run needed lives exactly as long as the
# child. On ctrl-c nu stops at once and skips that cleanup: the reaper resumes by itself at its deadline
# (REAPER_PAUSE_S), the state lock drops with the ssh holding it, and the temp dir stays in XDG_RUNTIME_DIR, which
# only this user reads, until logout.
#
# usage: sync.nu [<guest>...] [--skip-host] [--dry-run]: the named guests alone (vmid or name), the Proxmox host and
# terraform left out. A partial run commits nothing; the next full run commits the generation.
#
# env: TF_STATE_FRESH=1    first deploy of an empty lab (after deinit.nu too): no nas to pull from, a local copy is set aside
#      TF_STATE_OFFLINE=1  the nas is down: apply from the local state copy without its lock (it may be behind)
#      HOMELAB_PARALLEL    deploys at once (default DEPLOY_PARALLEL_DEFAULT)
# log: ~/.local/state/homelab/logs/sync-<utc time>.log, the last LOG_KEEP runs

const SELF = path self
const ROOT = path self | path dirname
const SRC = $ROOT | path join src
use src/scripts/lib/tools.nu [die sh-quote tools-require warn]
use src/scripts/lib/secrets.nu [secrets-age-key-lines secrets-age-key-ready secrets-dotfiles-dir]
use src/scripts/lib/tfstate.nu [tfstate-dir tfstate-lock-acquire tfstate-lock-release tfstate-pull tfstate-push tfstate-set-aside]
use src/scripts/lib/proxmox.nu [
    lab-files proxmox-tfvars-load proxmox-login proxmox-ssh-init proxmox-ca-write proxmox-converge
    PROXMOX_IMAGE PROXMOX_LXC_TEMPLATE PROXMOX_SSH_ALIVE_INTERVAL_S PROXMOX_SSH_ALIVE_COUNT
]
use src/scripts/lib/lab.nu [
    lab-ssh-try proxmox-ssh wait-for-ssh guest-status guest-wake guest-sleep host-keys-learn deploy-nixos SSH_CONNECT_TIMEOUT_S
]

const LOG_KEEP = 30
const ROUTER_NAME = "300-router"
const USER_KNOWN_HOSTS = ".ssh/known_hosts.homelab"
# after the router's own deploy: 2.5 minutes for the bastion, then 1 for the internal zone behind it
const ROUTER_WAIT_ATTEMPTS = 30
const INGRESS_WAIT_ATTEMPTS = 12
# the router's resolver after its deploy: 2 minutes, probed with a name every build pulls from
const DNS_WAIT_ATTEMPTS = 24
const DNS_WAIT_INTERVAL = 5sec
const DNS_PROBE_NAME = "ghcr.io"
# a zone gateway answers ssh within this when the house lan routes the zone here
const ROUTE_PROBE_TIMEOUT_S = 4
const PVE_API_PORT = 8006
# a fetch or push github does not answer within this gives up; the next run catches up
const GIT_TIMEOUT_S = 60
const NIX_FEATURES = [--extra-experimental-features "nix-command flakes"]
# a substituter or github that does not answer: each connection try ends after this, then the path builds locally or
# the evaluation fails; every nix of the run, terraform's too, and the daemon takes the setting from any user
const NIX_CONNECT_TIMEOUT_S = 15
const REAPER_PAUSE_FILE = "/run/ondemand-reaper-pause-until"
# outlives any sync, expires on its own if the run dies before it resumes the reaper
const REAPER_PAUSE_S = 14400
# the guests whose reaper the run paused, while it is paused: the parent resumes what the child left paused
const REAPER_PAUSED_NAME = "reaper-paused.nuon"
const SSH_CONFIG_NAME = "ssh_config"
const STATUS_NAME = "status"
# the child's env: the run's temp dir, whose presence makes this script the child
const RUN_DIR_ENV = "HOMELAB_SYNC_RUN"
const STATE_REMOTE = "/srv/nas/terraform/terraform.tfstate"
const STATE_LOCK_REMOTE = "/srv/nas/terraform/.lock"
const TF_ATTEMPTS = 5
const TF_RETRY = 5sec
const TF_PARALLELISM = 3
const DEPLOY_PARALLEL_DEFAULT = 6
# eval-only checks of the lab's rules: terraform's before the apply, the hosts' once the run's secrets are in place,
# which the secrets law reads
const TERRAFORM_LAW = "terraform-law"
const POLICY_LAW = "policy-eval"
const TRUST_DEFAULT = "/etc/ssl/certs/ca-certificates.crt"
# ssh runs a ProxyCommand through $SHELL -c, and the owner's login shell is not sh
const PROXY_SHELL = "/bin/sh"
# the anti-spoofing every source-address guard of the lab relies on (terraform/lib.tf `ipfilter`), read back from what
# proxmox-firewall loaded (pve-install.nu sets its nftables backend); the firewalled guests' ids on stdin
const FIREWALL_CHECK_REMOTE = r#'set -u
systemctl is-active -q proxmox-firewall || { echo "proxmox-firewall is not running"; exit 1; }
chains=$(nft list table bridge proxmox-firewall-guests) || { echo "proxmox-firewall loaded no guest chains"; exit 1; }
unguarded=""
while read -r id; do
  printf '%s\n' "$chains" | grep -Eq "ip saddr @v4-guest-$id/spoofed[ ;].*drop" || unguarded="$unguarded $id"
done
[ -z "$unguarded" ] || { echo "no drop of spoofed sources loaded for:$unguarded (nft list chain bridge proxmox-firewall-guests guest-<id>-out)"; exit 1; }'#
# what terraform's token may not set (root@pam only): lxc features (a change restarts the container) and lxc onboot
# (bpg 0.70 never reads it back, so drift there is invisible to terraform; on-demand containers stay off at host
# boot); "<id> <features> <onboot>" lines on stdin
const GUEST_SETTINGS_REMOTE = r#'set -euo pipefail
sorted() { tr , '\n' | sort | paste -sd, -; }
while read -r id features onboot; do
  config=$(pct config "$id")
  have=$(sed -n 's/^features: //p' <<<"$config" | sorted)
  if [ "$(sorted <<<"$features")" != "$have" ]; then
    echo ">>> lxc-$id features: ${have:-none} -> $features"
    pct set "$id" --features "$features"
    if pct status "$id" | grep -q running; then pct reboot "$id"; fi
  fi
  if [ "$(sed -n 's/^onboot: //p' <<<"$config")" != "$onboot" ]; then
    pct set "$id" --onboot "$onboot"
    echo ">>> lxc-$id onboot -> $onboot"
  fi
done'#

def state-home []: nothing -> path {
    $env.XDG_STATE_HOME? | default ($env.HOME | path join .local state)
}

# flakes see git-tracked files only: tracked changes and what this run generates are staged, nothing else, so a stray
# file under src never reaches the public repo; a new instance or app folder is `git add`ed by its author
def stage-declared []: nothing -> nothing {
    ^git -C $ROOT add -u
    ^git -C $ROOT add -A -- .sops.yaml src/generated ':(glob)src/**/age.pub' ':(glob)src/**/age.sops' ':(glob)src/**/*.sops.json'
}

def secrets-check []: nothing -> bool {
    try { ^$nu.current-exe --no-config-file ($SRC | path join scripts secrets-check.nu) --require-values; true } catch { false }
}

def --wrapped nix-eval-json [what: string, ...args: string]: nothing -> any {
    let printed = try { ^nix eval ...$NIX_FEATURES --json --no-warn-dirty ...$args } catch {
        die $"($what) does not evaluate \(nix eval ($args | first)\)."
    }
    $printed | from json
}

# the same facts every host and terraform read, and the desktop clients' interface (modules/lab-export.nix)
def lab-eval []: nothing -> record {
    {
        inventory: (nix-eval-json "the lab's instances" $"($SRC)#lab.inventory")
        exported: (nix-eval-json "the desktop clients' export" $"($SRC)#lab.export")
    }
}

def lab-export-text [exported: record]: nothing -> string {
    $"($exported | to json --indent 2)\n"
}

# true when the lab keeps the law; what it breaks printed
def law-check [law: string]: nothing -> bool {
    let built = do { ^nix build $"($SRC)#checks.x86_64-linux.($law)" ...$NIX_FEATURES --no-link } | complete
    if $built.exit_code != 0 { print -e $built.stderr }
    $built.exit_code == 0
}

# the ids of the named guests (vmid, name, or the router's folder name), every guest's for none
def guests-select [inventory: record, names: list<string>]: nothing -> list<string> {
    let guests = $inventory | transpose id guest | each {|g|
        let router = if $g.guest.type == "router" { [$ROUTER_NAME] } else { [] }
        {id: $g.id, names: ([$g.id $g.guest.name] ++ $router)}
    }
    if ($names | is-empty) { return $guests.id }
    let unknown = $names | where {|n| not ($guests | any { $n in $in.names }) }
    if ($unknown | is-not-empty) { die $"no guest named ($unknown | str join ', ')." }
    $guests | where {|g| $names | any { $in in $g.names } } | get id
}

# a phase's first line, with the time since the run began: the log shows where a run spends it
def phase-print [started: datetime, name: string]: nothing -> nothing {
    let elapsed_s = ((date now) - $started) / 1sec | math floor
    print $">>> [+($elapsed_s)s] ($name)"
}

# the deploy order: the router first (the ssh bastion), the nas alone next (its clients hard-mount it), then the
# always-on guests in parallel, the scale-to-zero ones one at a time; an unpowered guest is neither built nor deployed
def deploy-plan [inventory: record, nas_id: string, selected: list<string>]: nothing -> record {
    let guests = $inventory | transpose id guest | where id in $selected
    let deployed = $guests | where { $in.guest.type != "router" and $in.guest.powered }
    let rest = $deployed | where { $in.id != $nas_id }
    {
        guests: $deployed
        nas: ($deployed | where id == $nas_id | get --optional 0)
        parallel: ($rest | where { $in.guest.idle == null })
        idle: ($rest | where { $in.guest.idle != null })
        unpowered: ($guests | where { not $in.guest.powered } | get id)
        router: ($guests | any { $in.guest.type == "router" })
    }
}

def deploy-parallel []: nothing -> int {
    $env.HOMELAB_PARALLEL? | default $DEPLOY_PARALLEL_DEFAULT | into int
}

# a deadline, not a stop: switch-to-configuration restarts timers.target and with it a stopped reaper timer. The
# guests are recorded before the pause, so a run that dies halfway still gets them resumed.
def reaper-pause [lab: record, run: path, ids: list<string>]: nothing -> nothing {
    let ips = $ids | each {|id| $lab.inventory | get $id | get ip }
    {ips: $ips, ssh_config: $lab.ssh_config} | to nuon | save --force ($run | path join $REAPER_PAUSED_NAME)
    for ip in $ips {
        if (lab-ssh-try $lab $ip $"echo $\(\($\(date +%s\) + ($REAPER_PAUSE_S)\)\) > ($REAPER_PAUSE_FILE)").exit_code != 0 {
            warn $"could not pause the on-demand reaper on ($ip)"
        }
    }
}

# what reaper-pause recorded; safe when nothing is paused
def reaper-resume [run: path]: nothing -> nothing {
    let paused_file = $run | path join $REAPER_PAUSED_NAME
    if not ($paused_file | path exists) { return }
    let paused = open --raw $paused_file | from nuon
    $env.SHELL = $PROXY_SHELL
    for ip in $paused.ips {
        let resumed = do {
            ^ssh -F $paused.ssh_config -o $"ConnectTimeout=($SSH_CONNECT_TIMEOUT_S)" $"root@($ip)" $"rm -f ($REAPER_PAUSE_FILE)"
        } | complete
        if $resumed.exit_code != 0 { warn $"could not resume the on-demand reaper on ($ip), it resumes by itself at the deadline" }
    }
    rm --force $paused_file
}

# the nas side of lib/tfstate.nu; the lock lives as long as its ssh's stdin, which the run holds open
def tfstate-transport [lab: record, nas_ip: string]: nothing -> record {
    let dir = $STATE_REMOTE | path dirname
    {
        read: {|out|
            let got = lab-ssh-try $lab $nas_ip $"if [ -f ($STATE_REMOTE) ]; then cat ($STATE_REMOTE); else echo NO_STATE; fi"
            if $got.exit_code != 0 { return 1 }
            if ($got.stdout | str trim) == "NO_STATE" { return 2 }
            $got.stdout | save --force $out
            0
        }
        # the previous state stays next to it; kopia keeps the history
        write: {|file|
            let remote = $"umask 077 && mkdir -p ($dir) && cat > ($STATE_REMOTE).new && sync ($STATE_REMOTE).new && { [ ! -f ($STATE_REMOTE) ] || cp -p ($STATE_REMOTE) ($STATE_REMOTE).prev; } && mv ($STATE_REMOTE).new ($STATE_REMOTE)"
            (open --raw $file | lab-ssh-try $lab $nas_ip $remote).exit_code == 0
        }
        lock: {|| ^ssh -F $lab.ssh_config -o $"ConnectTimeout=($SSH_CONNECT_TIMEOUT_S)" $"root@($nas_ip)" $"mkdir -p ($dir) && { flock -n ($STATE_LOCK_REMOTE) -c 'echo locked; exec cat >/dev/null' || echo busy; }" }
    }
}

# per zone direct where the house lan routes it (a fritzbox static route), else through the router bastion; every
# host key checked against src/generated/known_hosts. The deploy key is named too: the parent's cleanup runs after
# the run's agent ended.
def ssh-config-write [inventory: record, known_hosts: path, router: string, identity: path, file: path]: nothing -> nothing {
    let gateways = $inventory | values | where type != router | get gateway | uniq | sort
    let ssh = which ssh | get 0.path
    let bastions = $gateways | each {|gateway|
        let zone = $"($gateway | str replace --regex '\.[0-9]+$' '').*"
        # the zone's gateway answers ssh on the router's wan side whenever the zone is routed here
        let routed = (do { ^ssh-keyscan -T $ROUTE_PROBE_TIMEOUT_S -t ed25519 $gateway } | complete).stdout | str trim | is-not-empty
        if $routed {
            print $">>> ($zone) directly routable: no bastion."
            []
        } else {
            print $">>> ($zone) not routed from here: through the router bastion."
            [$"Host ($zone)" $"  ProxyCommand ($ssh) -F ($file) -W %h:%p root@($router)"]
        }
    } | flatten
    let all = [
        "Host *" $"  UserKnownHostsFile ($known_hosts)" "  StrictHostKeyChecking yes" "  HostKeyAlgorithms ssh-ed25519"
        $"  IdentityFile ($identity)"
        $"  ServerAliveInterval ($PROXMOX_SSH_ALIVE_INTERVAL_S)" $"  ServerAliveCountMax ($PROXMOX_SSH_ALIVE_COUNT)"
    ]
    $bastions ++ $all | each { $"($in)\n" } | str join | save --force $file
}

def build-targets [names: list<string>]: nothing -> list<string> {
    $names | each { $"($SRC)#nixosConfigurations.($in).config.system.build.toplevel" }
}

# one nix process for every closure, run beside the router's deploy: one per vm ran the workstation out of memory;
# its result arrives as a message
def build-start [names: list<string>, out_dir: path, tag: int]: nothing -> nothing {
    let targets = build-targets $names
    job spawn {
        let built = if ($targets | is-empty) { {exit_code: 0, stdout: "", stderr: ""} } else {
            do { ^nix build ...$targets ...$NIX_FEATURES --keep-going --out-link ($out_dir | path join result) } | complete
        }
        $built | job send --tag $tag 0
    } | ignore
}

# name -> toplevel; a name whose closure failed maps to "", and nix links no result once any build failed, so the
# toplevels that did build are looked up in the store
def build-toplevels [names: list<string>, out_dir: path, ok: bool]: nothing -> record {
    if $ok {
        # nix names the out link of installable i result-i, the first plain result
        $names | enumerate | reduce --fold {} {|e, acc|
            let link = $out_dir | path join (if $e.index == 0 { "result" } else { $"result-($e.index)" })
            $acc | insert $e.item ($link | path expand)
        }
    } else {
        let paths = nix-eval-json "the guests' toplevels" $"($SRC)#nixosConfigurations" --apply $"cs: map \(n: cs.${n}.config.system.build.toplevel.outPath\) \(builtins.fromJSON ''($names | to json --raw)''\)"
        $names | zip $paths | reduce --fold {} {|pair, acc| $acc | insert $pair.0 (if ($pair.1 | path exists) { $pair.1 } else { "" }) }
    }
}

# the terraform state pulled from the nas under its lock, applied, pushed back; false when the push failed
def terraform-sync [lab: record, nas_id: string, tfvars_file: path, ca: path, nix_trust: string]: nothing -> bool {
    let tf_dir = $SRC | path join terraform
    let tfstate_local = tfstate-dir | path join terraform.tfstate
    # the providers live beside the state, outside the flake tree, which a path: evaluation copies whole into the
    # world-readable store
    $env.TF_DATA_DIR = tfstate-dir | path join data
    ^install -d -m 700 (tfstate-dir)
    # idempotent; installs a provider main.tf gained since the last run (the lock file pins it); -reconfigure: the path
    # is the only backend setting, and the state already lives there
    let init = do { ^terraform $"-chdir=($tf_dir)" init -input=false -reconfigure $"-backend-config=path=($tfstate_local)" } | complete
    if $init.exit_code != 0 {
        print -e $init.stdout $init.stderr
        die "terraform init failed (above)."
    }
    let offline = ($env.TF_STATE_OFFLINE? | default "0") == "1"
    let transport = tfstate-transport $lab ($lab.inventory | get $nas_id | get ip)
    mut lock: record = {job: null}
    if $offline {
        if not ($tfstate_local | path exists) { die $"TF_STATE_OFFLINE=1 needs the local copy ($tfstate_local)." }
        warn "TF_STATE_OFFLINE=1: applying from the local state copy, unlocked; it may be behind the nas."
    } else if ($env.TF_STATE_FRESH? | default "0") == "1" {
        # an empty lab has no nas to lock or pull from; a copy of an earlier lab would make terraform look for its guests
        let aside = tfstate-set-aside $tfstate_local
        if $aside != "" { print $aside }
        print ">>> Terraform state: starting empty (TF_STATE_FRESH=1)."
    } else {
        # the nas guest's own key first: the lock and the state travel over ssh to it
        host-keys-learn $lab [$nas_id]
        $lock = tfstate-lock-acquire $transport
        if not $lock.ok { die ($lock.message | str replace "ERROR: " "") }
        let pulled = tfstate-pull $transport $tfstate_local
        print $pulled.message
        if not $pulled.ok {
            tfstate-lock-release $lock
            die "the terraform state was not pulled (above)."
        }
    }
    # every run, with refresh: proxmox drift (a half-failed apply, a manual edit) is corrected, never trusted
    print ">>> Terraform: applying..."
    for attempt in 1..$TF_ATTEMPTS {
        let applied = with-env {SSL_CERT_FILE: $ca, NIX_SSL_CERT_FILE: $nix_trust} {
            try { ^terraform $"-chdir=($tf_dir)" apply -auto-approve $"-parallelism=($TF_PARALLELISM)" $"-var-file=($tfvars_file)"; true } catch { false }
        }
        if $applied { break }
        if $attempt == $TF_ATTEMPTS {
            # a failed apply still writes the state; the apply's failure is the error reported, not the push's
            if not $offline { print (tfstate-push $transport $tfstate_local).message }
            tfstate-lock-release $lock
            die $"Terraform failed after ($TF_ATTEMPTS) attempts."
        }
        print $"Retrying \(($attempt)/($TF_ATTEMPTS)\)..."
        sleep $TF_RETRY
    }
    if $offline { return true }
    # TF_STATE_FRESH: the nas guest terraform just created
    if $lock.job == null { host-keys-learn $lab [$nas_id] }
    let pushed = tfstate-push $transport $tfstate_local
    if $pushed.message != "" { print $pushed.message }
    # the state is settled: a deploy that hangs below never holds another sync's apply
    tfstate-lock-release $lock
    $pushed.ok
}

# what was deployed, even on partial failure: tracked changes anywhere (a generation never pairs new configs with an
# old sync.nu) and what the run generated; false when it is not committed
def generation-commit []: nothing -> bool {
    stage-declared
    if (do { ^git -C $ROOT diff --cached --quiet } | complete).exit_code == 0 { return true }
    if not (secrets-check) {
        print "ERROR: not committed: the staged tree would publish a secret (above). Unstage or encrypt it, then commit."
        return false
    }
    let count = ^git -C $ROOT rev-list --count HEAD
    let next = ($count | str trim | into int) + 1
    print $">>> Git: committing generation ($next)"
    let committed = try { ^git -C $ROOT commit -m $"Generation: ($next)"; true } catch { false }
    if not $committed {
        print "ERROR: the generation is not committed (above)."
        return false
    }
    if (do { ^timeout $GIT_TIMEOUT_S git -C $ROOT push } | complete).exit_code != 0 {
        # the next run pushes what this one could not
        warn "github unavailable: the generation is not pushed yet."
    }
    true
}

def sync-run [run: path, names: list<string>, skip_host: bool]: nothing -> int {
    let started = date now
    tools-require git sops ssh ssh-keygen ssh-keyscan ssh-add terraform nix curl openssl ip timeout
    $env.SHELL = $PROXY_SHELL
    let files = lab-files $SRC

    secrets-age-key-ready ($ROOT | path join secrets age.txt)
    # deploys log in with this key; src/secrets/keys/ authorizes it everywhere; a fresh dotfiles install has it only in
    # the dotfiles secrets
    let deploy = if ($env.HOME | path join .ssh id_ed25519.pub | path exists) {
        {key: ($env.HOME | path join .ssh id_ed25519), pub: ($env.HOME | path join .ssh id_ed25519.pub)}
    } else {
        {key: (secrets-dotfiles-dir | path join ssh_privatekey.asc), pub: (secrets-dotfiles-dir | path join ssh_publickey.asc)}
    }
    $env.NIX_CONFIG = [($env.NIX_CONFIG? | default "") $"connect-timeout = ($NIX_CONNECT_TIMEOUT_S)"] | where $it != "" | str join "\n"

    phase-print $started "EVALUATING THE LAB"
    let evaluated = lab-eval
    let inventory = $evaluated.inventory
    let exported = $evaluated.exported
    let selected = guests-select $inventory $names
    let partial = ($names | is-not-empty) or $skip_host
    # committed with the generation; beside it, so the rename is atomic and a failed eval keeps the old one
    let lab_export = $SRC | path join generated lab.json
    let export_new = mktemp --tmpdir-path ($lab_export | path dirname) lab.json.XXXXXX
    lab-export-text $exported | save --force $export_new
    ^chmod 644 $export_new
    mv --force $export_new $lab_export
    # the ingresses run the on-demand reaper, which must not shut a guest down mid-deploy
    let ondemand_ids = $exported.zones | values | get --optional ingress | compact | each { into string }
    # the internal ingress: the first guest reached through the router bastion
    let ingress_id = $exported.zones.internal.ingress | into string
    # the clients hard-mount it: it deploys before them, and it holds the terraform state
    let nas_id = $exported.routes.nas.vmid | into string
    let site = open $files.site

    # github unavailable: the last fetched upstream is the one compared
    if (do { ^timeout $GIT_TIMEOUT_S git -C $ROOT fetch origin --quiet } | complete).exit_code != 0 {
        warn "github unavailable: checked against the upstream as last fetched."
    }
    let behind = do { ^git -C $ROOT rev-list "HEAD..@{u}" --count } | complete | get stdout | str trim
    if ($behind | is-not-empty) and ($behind | into int) > 0 { die $"Branch is ($behind) commit\(s\) behind upstream. Run 'git pull' first." }

    phase-print $started (if $skip_host { "PROXMOX (the host left as it is)" } else { "PROXMOX" })
    let tfvars = proxmox-tfvars-load $SRC
    if $tfvars == null { die "Missing tfvars. Run ./src/scripts/init.nu first." }
    let login = proxmox-login $tfvars
    let proxmox_host = $site.lan.proxmox
    let ssh = proxmox-ssh-init $SRC $proxmox_host $login.port
    # the owner's own ssh sees what this run trusts
    mkdir ($env.HOME | path join .ssh)
    ^ln -sfn $files.known_hosts ($env.HOME | path join $USER_KNOWN_HOSTS)

    let deploy_key_field = if ($deploy.pub | path exists) { open --raw $deploy.pub | split row " " | get --optional 1 } else { null }
    let authorized = glob ($SRC | path join secrets keys *.pub) | each { open --raw $in } | str join
    if $deploy_key_field == null or not ($authorized | str contains $deploy_key_field) {
        die $"($deploy.pub) is not in src/secrets/keys/. Add it, then deploy once from a machine whose key is."
    }
    # the bpg provider imports vm disks over ssh, through the agent
    if (do { ^ssh-add -T $deploy.pub } | complete).exit_code != 0 and ("" | do { ^ssh-add $deploy.key } | complete).exit_code != 0 {
        warn "could not add the deploy key to the ssh-agent."
    }

    let lab_base = {src: $SRC, inventory: $inventory, known_hosts: $files.known_hosts, ssh_config: ($run | path join $SSH_CONFIG_NAME)
        proxmox: {ssh: $ssh, user: $login.user, host: $proxmox_host, port: $login.port}}
    if (do { proxmox-ssh $lab_base "true" } | complete).exit_code != 0 {
        die $"Cannot reach Proxmox at ($proxmox_host):($login.port), or its host key changed."
    }

    # the host as the lab declares it, before terraform needs its bridges, tokens and storage; a token it had to create
    # lands in the tfvars and secrets, so the tfvars are read after it
    if not $skip_host { proxmox-converge $SRC $ssh $login.user $lab_export "" }
    let tfvars = proxmox-tfvars-load $SRC
    let tfvars_file = $run | path join tfvars.json
    ^install -m 600 /dev/null $tfvars_file
    $tfvars | to json | save --append $tfvars_file
    # terraform and curl verify the api against the cluster CA; the node certificate names the host's address
    let ca = $run | path join pve-ca.pem
    proxmox-ca-write $SRC $ca
    # terraform runs nix (lib.tf's guests), which keeps the trust it has: nix's own lookup order
    let nix_trust = $env.NIX_SSL_CERT_FILE? | default $env.SSL_CERT_FILE? | default $TRUST_DEFAULT
    # the proxmox firewall admits the api from the owner's machines only (terraform/lib.tf, operators)
    let route = do { ^ip -4 route get $proxmox_host } | complete
    let operator = $route.stdout | parse --regex ' src (?<ip>[0-9.]+)' | get --optional 0.ip | default ""
    if $operator not-in [$site.lan.workstation? $site.lan.notebook?] {
        die ([
            $"this machine reaches Proxmox from ($operator), which is neither site.json's lan.workstation nor lan.notebook:"
            "       the Proxmox firewall drops its api calls. Deploy from one of them, or rerun src/scripts/init.nu here."
        ] | str join "\n")
    }
    let api_url = $"https://($proxmox_host):($PVE_API_PORT)/api2/json"
    # tls alone first: the ingresses' wake and reaper, their proxmox route and terraform all verify the host by its address
    if (do { ^curl -s --cacert $ca -o /dev/null $"($api_url)/version" } | complete).exit_code != 0 {
        die ([
            $"the Proxmox api certificate does not name ($proxmox_host) or does not chain to site.json's proxmoxCa,"
            "       though pve-install.nu re-signs it: openssl x509 -in /etc/pve/local/pve-ssl.pem -noout -ext subjectAltName"
        ] | str join "\n")
    }
    # a header file, out of argv
    let auth = $run | path join pve-auth
    ^install -m 600 /dev/null $auth
    $"Authorization: PVEAPIToken=($tfvars.proxmox_api_token_id?)=($tfvars.proxmox_api_token_secret?)\n" | save --append $auth
    let lab = $lab_base | merge {api: {url: $api_url, node: $site.node, ca: $ca, auth: $auth}}
    if (do { ^curl -sf --cacert $ca -H $"@($auth)" -o /dev/null $"($api_url)/version" } | complete).exit_code != 0 {
        die "the Proxmox api refused the token."
    }

    if not $skip_host {
        # the golden image, and the lxc template, which only seeds new containers, so it is uploaded once
        let scp = [scp -P ($login.port | into string) -o $"UserKnownHostsFile=($files.known_hosts)" -o StrictHostKeyChecking=yes]
        if (do { proxmox-ssh $lab $"test -f ($PROXMOX_IMAGE)" } | complete).exit_code != 0 {
            let image = $ROOT | path join images nixos.img
            if not ($image | path exists) { die "Golden image missing. Run: sudo nix build ./src#cloud-image" }
            print ">>> Uploading golden image..."
            ^$scp.0 ...($scp | skip 1) $image $"($login.user)@($proxmox_host):($PROXMOX_IMAGE)"
        }
        if (do { proxmox-ssh $lab $"test -f ($PROXMOX_LXC_TEMPLATE)" } | complete).exit_code != 0 {
            print ">>> Building and uploading the LXC template..."
            let tarball = ^nix build $"($SRC)#lxc-template" ...$NIX_FEATURES --no-link --print-out-paths
            ^$scp.0 ...($scp | skip 1) (glob ($tarball | str trim | path join tarball *.tar.xz) | first) $"($login.user)@($proxmox_host):($PROXMOX_LXC_TEMPLATE)"
        }
    }

    ssh-config-write $inventory $files.known_hosts $site.lan.router $deploy.key $lab.ssh_config
    $env.NIX_SSHOPTS = $"-F ($lab.ssh_config)"

    mut failure = false
    if not $skip_host {
        phase-print $started "TERRAFORM"
        if not (law-check $TERRAFORM_LAW) { die $"terraform breaks its law \(($TERRAFORM_LAW), above\): nothing applied." }
        if not (terraform-sync $lab $nas_id $tfvars_file $ca $nix_trust) { $failure = true }
        let lxc_settings = $inventory | items {|id, guest|
            if $guest.kind == "lxc" { $"($id) ($guest.features) (if $guest.powered and $guest.idle == null { 1 } else { 0 })" }
        } | compact | str join "\n"
        if not (try { $"($lxc_settings)\n" | proxmox-ssh $lab $"bash -c (sh-quote $GUEST_SETTINGS_REMOTE)"; true } catch { false }) {
            print "ERROR: Proxmox did not take the guests' root-only settings (above)."
            $failure = true
        }
    }
    let firewalled = $inventory | items {|id, guest| if $guest.type != "router" { $id } } | compact | str join "\n"
    let firewall = $"($firewalled)\n" | do { proxmox-ssh $lab $"sh -c (sh-quote $FIREWALL_CHECK_REMOTE)" } | complete
    if $firewall.exit_code != 0 {
        print $"ERROR: a guest can take a neighbour's address: ($firewall.stdout | str trim)"
        $failure = true
    }

    let plan = deploy-plan $inventory $nas_id $selected
    if ($plan.unpowered | is-not-empty) { print $">>> Powered-off VMs, neither built nor deployed: ($plan.unpowered | str join ' ')" }

    # the traefiks are always on: pause their reaper before waking anything it could stop again; the parent resumes it
    # however the run ends
    host-keys-learn $lab $ondemand_ids
    reaper-pause $lab $run $ondemand_ids

    # the always-on guests must run to receive a deploy; a scale-to-zero one wakes alone, just before its own deploy,
    # so the run never starts every idle guest at once (their memory together is more than the host has)
    let always_on = $inventory | transpose id guest | where { $in.id in $selected and $in.guest.powered and $in.guest.idle == null }
        | get id
    for id in $always_on { guest-wake $lab $id }
    print ">>> Reading every running guest's host key through Proxmox..."
    host-keys-learn $lab $always_on

    phase-print $started "SECRETS AND BUILD"
    stage-declared
    # every secret, key and rule where the configs say; staged again so the build sees them
    let host_keys_file = $run | path join host-keys.json
    ^$nu.current-exe --no-config-file ($SRC | path join scripts secrets-sync.nu) --apply --host-keys-out $host_keys_file
    let host_keys = open $host_keys_file
    stage-declared
    let untracked = ^git -C $ROOT ls-files --others --exclude-standard -- src
    if ($untracked | str trim) != "" { warn $"untracked, neither built nor committed \(git add what belongs to the lab\):\n($untracked | str trim)" }
    # the repo is public: stop before anything is built from, or committed with, a plaintext secret
    ^git -C $ROOT config core.hooksPath .githooks
    if not (secrets-check) { die "the staged tree would publish a secret (above)." }
    if not (law-check $POLICY_LAW) { die $"the lab breaks its law \(($POLICY_LAW), above\): nothing built or deployed." }

    let names_built = $plan.guests | each { $in.guest.name }
    # out links are gc roots until the deploys are done
    let build_dir = $run | path join build
    mkdir $build_dir
    let build_tag = random int 1..2147483647
    build-start $names_built $build_dir $build_tag

    # {guest, ok, seconds} of one deploy
    let deploy_one = {|name: string, ip: string, toplevel: any|
        let began = date now
        let key = $host_keys | get --optional $name
        let ok = if $key == null {
            print $"ERROR: no age key for ($name): secrets-sync.nu did not plan it"
            false
        } else {
            deploy-nixos $lab $name $ip $toplevel $key
        }
        {guest: $name, ok: $ok, seconds: (((date now) - $began) / 1sec | math floor)}
    }

    phase-print $started "DEPLOY"
    let router_ip = $site.lan.router
    let router_result = if not $plan.router { [] } else {
        let deployed = do $deploy_one $ROUTER_NAME $router_ip null
        if $deployed.ok {
            print ">>> Waiting for router bastion..."
            if not (wait-for-ssh $lab $router_ip $ROUTER_WAIT_ATTEMPTS) { die "Router unreachable after deploy." }
            # a wait, not a gate: a guest behind it that stays unreachable fails its own deploy
            print ">>> Verifying bastion -> internal subnet..."
            wait-for-ssh $lab ($inventory | get $ingress_id | get ip) $INGRESS_WAIT_ATTEMPTS | ignore
            print ">>> Verifying router DNS..."
            for _ in 1..$DNS_WAIT_ATTEMPTS {
                if (lab-ssh-try $lab $router_ip $"dig +short +timeout=2 ($DNS_PROBE_NAME) @127.0.0.1 2>/dev/null | grep -q .").exit_code == 0 { break }
                sleep $DNS_WAIT_INTERVAL
            }
        }
        [$deployed]
    }

    print ">>> Waiting for builds..."
    let built = job recv --tag $build_tag
    print $built.stdout $built.stderr
    if $built.exit_code != 0 {
        # a fetch that failed (a registry or github unavailable) fails only the hosts needing it
        print "ERROR: not every closure built (above): the hosts whose closure did are deployed, the others fail."
        $failure = true
    } else {
        print ">>> All builds complete."
    }
    let toplevels = build-toplevels $names_built $build_dir ($built.exit_code == 0)

    # a guest the run cannot address is skipped, not failed
    let addressed = {|g: record|
        if ($g.guest.ip? | is-empty) { print $">>> WARNING: No IP for ($g.guest.name), skipping." }
        $g.guest.ip? | is-not-empty
    }
    let nas_result = if $plan.nas == null or not (do $addressed $plan.nas) { [] } else {
        [(do $deploy_one $plan.nas.guest.name $plan.nas.guest.ip ($toplevels | get --optional $plan.nas.guest.name))]
    }

    let parallel = deploy-parallel
    print $">>> Deploying VMs \(up to ($parallel) in parallel\)..."
    let parallel_results = $plan.parallel | where { do $addressed $in } | par-each --threads $parallel {|g|
        # the reaper may have stopped it meanwhile
        guest-wake $lab $g.id
        do $deploy_one $g.guest.name $g.guest.ip ($toplevels | get $g.guest.name)
    }
    let idle_results = $plan.idle | where { do $addressed $in } | each {|g|
        let was = guest-status $lab $g.id
        guest-wake $lab $g.id
        host-keys-learn $lab [$g.id]
        let deployed = do $deploy_one $g.guest.name $g.guest.ip ($toplevels | get $g.guest.name)
        if $was == "stopped" { guest-sleep $lab $g.id }
        $deployed
    }
    reaper-resume $run
    let results = $router_result ++ $nas_result ++ $parallel_results ++ $idle_results
    if ($results | is-not-empty) { print ($results | table --index false) }
    if ($results | any { not $in.ok }) { $failure = true }

    phase-print $started "COMMIT"
    if $partial {
        print ">>> A partial run commits nothing: the next full ./sync.nu commits the generation."
    } else if not (generation-commit) {
        $failure = true
    }

    if $failure {
        print "ERROR: One or more deployments, checks or the commit failed."
        return 1
    }
    phase-print $started (if $partial { "THE NAMED GUESTS ARE SYNCHRONIZED" } else { "LAB IS FULLY SYNCHRONIZED" })
    0
}

def sync-plan [names: list<string>, skip_host: bool]: nothing -> nothing {
    tools-require git nix
    $env.NIX_CONFIG = [($env.NIX_CONFIG? | default "") $"connect-timeout = ($NIX_CONNECT_TIMEOUT_S)"] | where $it != "" | str join "\n"
    print ">>> PLAN: evaluating, building and listing what ./sync.nu would deploy; nothing reaches the lab"
    let evaluated = lab-eval
    let inventory = $evaluated.inventory
    let exported = $evaluated.exported
    let selected = guests-select $inventory $names
    if not (law-check $TERRAFORM_LAW) { die $"terraform breaks its law \(($TERRAFORM_LAW), above\): the run would stop there." }
    if not (law-check $POLICY_LAW) {
        warn $"the lab breaks ($POLICY_LAW) \(above\): the run stops there unless its secrets-sync.nu --apply mends it."
    }
    let lab_export = $SRC | path join generated lab.json
    let export_current = if ($lab_export | path exists) { open --raw $lab_export } else { "" }
    if (lab-export-text $exported) != $export_current { print ">>> src/generated/lab.json would change (the run commits it)" }
    let nas_id = $exported.routes.nas.vmid | into string
    let plan = deploy-plan $inventory $nas_id $selected

    let state = if $skip_host {
        "--skip-host: the Proxmox host and terraform are left as they are"
    } else if ($env.TF_STATE_OFFLINE? | default "0") == "1" {
        "TF_STATE_OFFLINE=1: applied from the local copy, unlocked"
    } else if ($env.TF_STATE_FRESH? | default "0") == "1" {
        "TF_STATE_FRESH=1: the local copy is set aside, the apply starts empty"
    } else {
        "pulled from the nas under its lock, pushed after the apply"
    }
    print $">>> Terraform state: ($state); the apply itself needs the Proxmox api and is not planned here"
    let behind = do { ^git -C $ROOT rev-list "HEAD..@{u}" --count } | complete | get stdout | str trim
    if ($behind | is-not-empty) and ($behind | into int) > 0 { warn $"Branch is ($behind) commit\(s\) behind its last fetched upstream: the run stops there." }
    let dirty = do { ^git -C $ROOT status --porcelain -- src } | complete | get stdout | lines
    let untracked = $dirty | where { str starts-with "??" } | each { str substring 3.. }
    if ($untracked | is-not-empty) { warn $"untracked, neither built nor committed:\n($untracked | str join (char nl))" }
    let key = $ROOT | path join secrets age.txt
    if (secrets-age-key-lines $key | is-empty) {
        print ">>> Secrets: the dotfiles secrets are locked, their plan is skipped (the run asks for the YubiKey)"
    } else {
        print ">>> Secrets: what the run's secrets-sync.nu --apply would change"
        with-env {SOPS_AGE_KEY_FILE: $key} { ^$nu.current-exe --no-config-file ($SRC | path join scripts secrets-sync.nu) }
    }

    print ">>> Building every closure the run deploys..."
    let router = if $plan.router { [$ROUTER_NAME] } else { [] }
    let names_built = $router ++ ($plan.guests | each { $in.guest.name })
    let built = do { ^nix build ...(build-targets $names_built) ...$NIX_FEATURES --keep-going --no-link } | complete
    print -e $built.stderr
    let toplevels = build-toplevels $names_built "" false
    let step_of = {|g: record| if $g.id == $nas_id { 2 } else if $g.guest.idle == null { 3 } else { 4 } }
    let order = ($router | each { {step: 1, guest: $in} }) ++ ($plan.guests | each {|g| {step: (do $step_of $g), guest: $g.guest.name} })
        | sort-by step | each {|row| $row | insert toplevel ($toplevels | get $row.guest | default "" | if $in == "" { "BUILD FAILED" } else { $in }) }
    print ">>> Deploy order: 1 the router (the bastion), 2 the nas alone, 3 in parallel, 4 scale-to-zero, one at a time"
    print ($order | table --index false)
    print $">>> Parallel deploys: (deploy-parallel); on-demand ingresses whose reaper pauses: ($exported.zones | values | get --optional ingress | compact | str join ' ')"
    if ($plan.unpowered | is-not-empty) { print $">>> Powered off, neither built nor deployed: ($plan.unpowered | str join ' ')" }
    if $built.exit_code != 0 { die "not every closure builds (above): the run would deploy the others and fail." }
    if ($names | is-not-empty) or $skip_host { print ">>> A partial run: nothing is committed." }
    print ">>> PLAN COMPLETE: ./sync.nu applies it"
}

# Sync the lab, or the named guests alone (vmid or name), its output also in its log; --skip-host leaves the Proxmox
# host and terraform as they are; --dry-run evaluates, builds and prints the plan, touching nothing
def main [...guests: string, --skip-host, --dry-run]: nothing -> nothing {
    if $dry_run {
        sync-plan $guests $skip_host
        return
    }
    let child_run = $env | get --optional $RUN_DIR_ENV
    if $child_run != null {
        sync-run $child_run $guests $skip_host | into string | save --force ($child_run | path join $STATUS_NAME)
        return
    }

    tools-require ssh ssh-add ssh-agent tee
    let logs = state-home | path join homelab logs
    ^install -d -m 700 $logs
    let log = $logs | path join $"sync-(date now | date to-timezone UTC | format date '%Y%m%dT%H%M%SZ').log"
    glob ($logs | path join sync-*.log) | sort --reverse | skip ($LOG_KEEP - 1) | each { rm --force $in } | ignore
    $">>> Log: ($log)\n" | tee { print --no-newline } | save --append $log
    # secret files of the run (tfvars, the api header, the host keys) live here, only this user reads them
    let run = mktemp --directory --tmpdir-path ($env.XDG_RUNTIME_DIR? | default "/tmp") homelab-sync.XXXXXX
    # nu cannot redirect its own output: the run is a child whose output tee writes, and its status a file, since a
    # pipeline's status is its last command's. The bpg provider imports vm disks over ssh, through an agent; without one
    # holding a key, the child runs under an agent of its own, which ends with it.
    let child = [$nu.current-exe --no-config-file $SELF ...$guests] ++ (if $skip_host { [--skip-host] } else { [] })
    let argv = if (do { ^ssh-add -l } | complete).exit_code != 0 { [ssh-agent] ++ $child } else { $child }
    try {
        with-env {($RUN_DIR_ENV): $run} { ^$argv.0 ...($argv | skip 1) o+e>| ^tee -a $log }
    } catch {|e|
        print -e $"ERROR: the run ended: ($e.msg)"
    }
    reaper-resume $run
    let status_file = $run | path join $STATUS_NAME
    let code = if ($status_file | path exists) { open --raw $status_file | str trim } else { "1" }
    rm --recursive --force $run
    exit (if $code == "0" { 0 } else { 1 })
}
