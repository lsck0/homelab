# secrets-sync.nu in scratch repos with throwaway age keys: placement and isolation, kinds, guarded secrets, idempotence,
# moves between files, prune, hosts leaving, refusals, the admin-key rotation (fresh data keys, renewed host keys, the
# history splice), atomicity under injected sops failures, and one run over the real plan.
#
# usage: nu secrets_sync_test.nu <repo src dir> <seed> <dir of plans: base moved minus unman renamed problem real .json>

# injected faults per run: each draws the failing sops call from the seed
const FAULT_TRIALS = 12
# cross-decrypt pairs sampled over the real plan, whose full matrix is hosts x files decrypts
const REAL_PAIRS = 50
const CAT = "secrets/shared.sops.json"
const TFV = "terraform/terraform.tfvars.sops.json"
const ROUTER = "instances/core/300-router"
const HOST_A = "instances/preconfigured/100-internal-a"
const HOST_B = "instances/preconfigured/101-internal-b"
# a seed and the address tor 0.4.9 itself derived from it (its hostname file)
const ONION_SEED = "RCFGM1i8J76AFckn7Wjh3q8Plfq84CzNKRtKznH6BKk="
const ONION_ADDRESS = "22ymcrqdffp24cxrnkudyhxfy3hbfsmqqcfkra6p7u7r3nqykmaojmqd.onion"
const KEY_BYTES = 32
# glibc's rand(): 31 bits; draws take the high bits, the low ones of a power-of-two lcg cycle short
const LCG_MULTIPLIER = 1103515245
const LCG_INCREMENT = 12345
const LCG_MODULUS = 2147483648
const LCG_DRAW_SHIFT = 65536

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def ok [message: string]: nothing -> nothing { print $"ok: ($message)" }

def lcg-next [state: int]: nothing -> int { ($LCG_MULTIPLIER * $state + $LCG_INCREMENT) mod $LCG_MODULUS }
def lcg-draw [state: int, count: int]: nothing -> int { ($state // $LCG_DRAW_SHIFT) mod $count }

# the plaintext, null when the key does not open it
def dec [key: path, file: path]: nothing -> any {
    let plain = with-env {SOPS_AGE_KEY_FILE: $key} { do { ^sops --decrypt $file } | complete }
    if $plain.exit_code == 0 { $plain.stdout } else { null }
}

def opens [key: path, file: path]: nothing -> bool { (dec $key $file) != null }

def value [repo: path, file: string, key: path, name: string]: nothing -> any {
    dec $key ($repo | path join src $file) | from json | get --optional $name
}

def recipients [file: path]: nothing -> list<string> { open --raw $file | from json | get sops.age.recipient | sort }

def tree-hash [dir: path]: nothing -> list {
    glob ($dir | path join "**" "*") --no-dir --exclude [**/.git/**] | sort | each {|f| [($f | path relative-to $dir) (open --raw $f | hash sha256)] }
}

def hash-of [file: path]: nothing -> string { open --raw $file | hash sha256 }

def recipient-of [key_file: path]: nothing -> string {
    let recipient = ^age-keygen -y $key_file
    $recipient | str trim
}

# the files a configuration reads, per the plan
def reads-of [plan: record, c: string]: nothing -> list<string> {
    $plan.files | items {|file, readers| if $c in $readers { $file } } | compact
}

# the names a sops file should hold: the declared ones of a values file, a host's shared list for its copy
def names-of [plan: record, file: string]: nothing -> list<string> {
    if ($file | str ends-with "/secrets.shared.sops.json") {
        $plan.hosts | values | where { $"($in.home)/secrets.shared.sops.json" == $file } | get 0.shared | sort
    } else {
        $plan.secrets | items {|k, spec| if $spec.file == $file { $k } } | compact | sort
    }
}

def main [src_in: path, seed: int, plans: path]: nothing -> nothing {
    print $"seed=($seed)"
    let t = mktemp --directory
    cd $t
    for k in [A1 A2 A3] { ^age-keygen -o ($t | path join $"($k).key") e> /dev/null }
    let a1 = recipient-of A1.key
    let a2 = recipient-of A2.key
    let a3 = recipient-of A3.key
    let plan_of = {|name: string| open ($plans | path join $"($name).json") }
    let key_file = {|name: string| $t | path join $"($name).key" }

    # a scratch repo with the scripts under test and the terraform vars, encrypted to the admins A1 A2
    let repo_create = {|dir: path|
        mkdir ($dir | path join src terraform)
        # coreutils: nu's cp keeps the store's read-only modes on the directories it creates, then cannot fill them
        ^cp -r ($src_in | path join scripts) ($dir | path join src)
        ^chmod -R u+w ($dir | path join src)
        $"creation_rules:\n  - path_regex: src/terraform/terraform\\.tfvars\\.sops\\.json$\n    age: ($a1),($a2)\n" | save ($dir | path join .sops.yaml)
        with-env {SOPS_AGE_KEY_FILE: (do $key_file A1)} {
            '{"proxmox_api_token_secret": "tfvars-secret-value"}' | ^nu --no-config-file --stdin ($dir | path join src scripts sops-encrypt.nu) ($dir | path join src $TFV)
        }
    }
    # one run of the script under test: {exit_code, stdout, stderr}
    let sync_run = {|dir: path, key: string, admins: list<string>, plan: string, args: list<string>, settings: record|
        let env_run = {SOPS_AGE_KEY_FILE: (do $key_file $key), SECRETS_ADMIN_RECIPIENTS: ($admins | str join ' '), DOTFILES: ($t | path join no-dotfiles)}
        with-env ($env_run | merge $settings) {
            ^nu --no-config-file ($dir | path join src scripts secrets-sync.nu) --plan ($plans | path join $"($plan).json") ...$args | complete
        }
    }
    let sync = {|dir: path, key: string, admins: list<string>, plan: string, args: list<string>|
        let r = do $sync_run $dir $key $admins $plan $args {}
        if $r.exit_code != 0 { fail $"a run ($plan) ($args | str join ' ') failed: ($r.stdout)($r.stderr)" }
        $r.stdout
    }
    let refuses = {|dir: path, says: string, key: string, admins: list<string>, plan: string, args: list<string>|
        let before = tree-hash $dir
        let r = do $sync_run $dir $key $admins $plan $args {}
        let out = $"($r.stdout)($r.stderr)"
        if $r.exit_code != 1 { fail $"expected a refusal \(($says)\), got rc=($r.exit_code): ($out)" }
        if not ($out | str contains $says) { fail $"the refusal does not say '($says)': ($out)" }
        if (tree-hash $dir) != $before { fail $"a refused run \(($says)\) wrote to the repo" }
    }
    let host_key = {|repo: path, c: string, plan: record, out: path, key: string|
        let home = $plan.hosts | get $c | get home
        dec (do $key_file $key) ($repo | path join src $home age.sops) | save --force $out
    }
    # every file holds what the plan says, encrypted to exactly its readers and the admins, and every host key opens
    # exactly the files it reads
    let check_layout = {|dir: path, plan_name: string, key: string, admins: list<string>|
        let plan = do $plan_of $plan_name
        let pubs = $plan.hosts | columns | reduce --fold {} {|c, acc|
            let out = $t | path join $"($c).key"
            do $host_key $dir $c $plan $out $key
            let pub = recipient-of $out
            if (open --raw ($dir | path join src ($plan.hosts | get $c | get home) age.pub) | str trim) != $pub { fail $"($c)'s age.pub is not its key's" }
            $acc | insert $c $pub
        }
        let rules = open --raw ($dir | path join .sops.yaml) | lines
        for file in ($plan.files | columns) {
            let path = $dir | path join src $file
            if not ($path | path exists) { fail $"($file) is missing" }
            if $"  - path_regex: src/($file | str replace --all '.' '\.')$" not-in $rules { fail $".sops.yaml has no rule for ($file)" }
            let want = $admins ++ ($plan.files | get $file | each {|c| $pubs | get $c }) | sort
            if (recipients $path) != $want { fail $"($file) is not encrypted to exactly the admins and its readers" }
            if ($file | str ends-with age.sops) { continue }
            let got = dec (do $key_file $key) $path | from json | columns | sort
            if $got != (names-of $plan $file) { fail $"($file) holds ($got | to nuon), the plan says (names-of $plan $file | to nuon)" }
        }
        for c in ($plan.hosts | columns) {
            let reads = reads-of $plan $c
            for file in ($plan.files | columns) {
                let opened = opens ($t | path join $"($c).key") ($dir | path join src $file)
                if $opened and $file not-in $reads { fail $"($c)'s key opens ($file)" }
                if not $opened and $file in $reads { fail $"($c)'s key does not open ($file), which it reads" }
            }
        }
    }

    # 1 to 4: a first run over an empty repo, a first deploy
    let r = $t | path join repo
    do $repo_create $r
    do $refuses $r "vault in src/secrets/shared.sops.json" A1 [$a1 $a2] base [--apply]
    let run1 = do $sync $r A1 [$a1 $a2] base [--apply --generate-guarded --host-keys-out ($t | path join out.json)]
    do $check_layout $r base A1 [$a1 $a2]
    ok "1 every file the plan lists, with its names, encrypted to the admins and its readers; host keys open exactly theirs"

    let a1_key = do $key_file A1
    if (value $r $CAT $a1_key gen) !~ '^[0-9a-f]{32}$' { fail $"gen \(hex:16\) is (value $r $CAT $a1_key gen)" }
    let lk = value $r $CAT $a1_key lk
    if not ($lk | str starts-with "base64:") or ($lk | str substring 7.. | decode base64 | bytes length) != $KEY_BYTES { fail $"lk is no laravel key: ($lk)" }
    if (value $r instances/custom/x/secrets.sops.json $a1_key x-app) !~ '^GK[0-9a-f]{24}$' { fail "x-app is no garage key id" }
    if (value $r $CAT $a1_key vault) !~ '^[0-9a-f]{32}$' { fail $"vault \(guardsData:hex:16\) is (value $r $CAT $a1_key vault)" }
    if (value $r $CAT $a1_key wg | decode base64 | bytes length) != $KEY_BYTES { fail "wg is no 32-byte base64 wireguard key" }
    if (value $r $CAT $a1_key man) != "" or (value $r $CAT $a1_key pub) != "" { fail "manual and public are not empty" }
    let hs = value $r $CAT $a1_key hs
    if ($hs | decode base64 | bytes length) != $KEY_BYTES { fail "hs is no 32-byte base64 onion seed" }
    let onion_address = {|seed: string| $seed | ^nu --no-config-file --stdin ($src_in | path join scripts lib onion.nu) address | str trim }
    if (do $onion_address $ONION_SEED) != $ONION_ADDRESS { fail "lib/onion.nu derives another address than tor" }
    let onion = open ($r | path join src generated onions.json) | get hs
    if $onion !~ '^[a-z2-7]{56}\.onion$' or $onion != (do $onion_address $hs) { fail $"generated/onions.json names hs ($onion)" }
    if not ($run1 | str contains $"add     man -> ($CAT) \(empty, fill it: sops src/($CAT)\)") { fail "an empty manual secret is not reported" }
    if (value $r $"($HOST_A)/secrets.shared.sops.json" $a1_key shared) != (value $r $CAT $a1_key shared) { fail "a's shared copy differs from src/secrets/shared.sops.json" }
    ok "2 values by kind (hex, wireguard, laravel key, garage key id, guarded hex, onion and its address; manual and public empty), shared copies equal the source"

    let base_plan = do $plan_of base
    let tree_files = glob ($r | path join "**" "*") --no-dir | each { open --raw $in | into binary }
    let secret_values = dec $a1_key ($r | path join src $CAT) | from json | values | where { ($in | str length) > 0 } | append tfvars-secret-value
    let host_keys = $base_plan.hosts | columns | each {|c| open --raw ($t | path join $"($c).key") | str trim }
    for v in ($secret_values ++ $host_keys) {
        if ($tree_files | any { ($in | bytes index-of ($v | into binary)) >= 0 }) { fail "a plaintext value or a host private key lies in the repo" }
    }
    ok "3 no plaintext value and no host private key anywhere under the repo"

    let out_json = $t | path join out.json
    let mode = ^stat -c %a $out_json
    if ($mode | str trim) != "600" { fail "--host-keys-out is not mode 0600" }
    for c in ($base_plan.hosts | columns) {
        if (open $out_json | get $c) != (open --raw ($t | path join $"($c).key") | str trim) { fail $"--host-keys-out's ($c)" }
    }
    ok "4 --host-keys-out maps every configuration to its key, mode 0600"

    let d = $t | path join dotfiles secrets
    mkdir $d
    cp $a1_key ($d | path join age.txt)
    "desk-v1\n" | save ($d | path join desk)
    let dot_run = {|| let res = do $sync_run $r A1 [$a1 $a2] base [--apply] {DOTFILES: ($t | path join dotfiles)}; if $res.exit_code != 0 { fail $res.stderr } }
    do $dot_run
    if (value $r $CAT $a1_key df) != "desk-v1" { fail "df was not copied from the dotfiles" }
    "desk-v2\n" | save --force ($d | path join desk)
    do $dot_run
    if (value $r $CAT $a1_key df) != "desk-v2" { fail "df does not follow the dotfiles" }
    if (open --raw ($d | path join desk)) != "desk-v2\n" { fail "the run wrote the dotfiles" }
    do $sync $r A1 [$a1 $a2] base [--apply] | ignore
    if (value $r $CAT $a1_key df) != "desk-v2" { fail "locked dotfiles lost df" }
    ok "4b dotfiles: the lab copy follows the dotfiles' file, never the other way; locked dotfiles keep it"

    # 5 to 8: idempotence, dry run, moves, prune, hosts leaving
    ^git -C $r init -q
    ^git -C $r add -A
    ^git -C $r -c user.name=t -c user.email=t@t commit -qm run1
    let before = tree-hash $r
    let run2 = do $sync $r A1 [$a1 $a2] base [--apply]
    if (tree-hash $r) != $before { fail "a second run changed bytes" }
    if not ($run2 | str contains "0 file(s) changed") { fail $"a second run reports changes: ($run2)" }
    ok "5 a second run changes no byte"

    let gen = value $r $CAT $a1_key gen
    let router = hash-of ($r | path join src $ROUTER secrets.sops.json)
    let dry = do $sync $r A1 [$a1 $a2] moved []
    if (tree-hash $r) != $before { fail "a dry run wrote" }
    if not ($dry | str contains $"move    gen: ($CAT) -> ($HOST_A)/secrets.sops.json") { fail $"the dry run does not report the move: ($dry)" }
    do $sync $r A1 [$a1 $a2] moved [--apply] | ignore
    do $check_layout $r moved A1 [$a1 $a2]
    if (value $r $"($HOST_A)/secrets.sops.json" $a1_key gen) != $gen { fail "gen changed value on its move" }
    if (hash-of ($r | path join src $ROUTER secrets.sops.json)) != $router { fail "the move rewrote an unrelated file" }
    do $sync $r A1 [$a1 $a2] base [--apply] | ignore
    if (value $r $CAT $a1_key gen) != $gen { fail "gen changed value on its way back" }
    ok "6 a dry run reports and writes nothing; a value moves into its new file and back unchanged, unrelated files untouched"

    let unman = do $sync $r A1 [$a1 $a2] unman [--apply]
    if not ($unman | str contains $"unused  man in ($CAT)") or "man" not-in (dec $a1_key ($r | path join src $CAT) | from json | columns) {
        fail "an undeclared value is not kept and reported"
    }
    dec $a1_key ($r | path join src $TFV) | from json | insert proxmox_ssh_password tfvars-dead-value | to json
        | with-env {SOPS_AGE_KEY_FILE: $a1_key} { ^nu --no-config-file --stdin ($r | path join src scripts sops-encrypt.nu) ($r | path join src $TFV) }
    do $sync $r A1 [$a1 $a2] unman [--apply --prune] | ignore
    if "man" in (dec $a1_key ($r | path join src $CAT) | from json | columns) { fail "--prune kept man" }
    if "proxmox_ssh_password" in (dec $a1_key ($r | path join src $TFV) | from json | columns) { fail "--prune kept the dead tfvars key" }
    if (value $r $TFV $a1_key proxmox_api_token_secret) != "tfvars-secret-value" { fail "--prune touched a declared tfvars value" }
    do $sync $r A1 [$a1 $a2] base [--apply] | ignore
    ok "7 an undeclared value is kept and reported, --prune deletes it, in the terraform vars too"

    let a_before = hash-of ($r | path join src $HOST_A secrets.sops.json)
    do $sync $r A1 [$a1 $a2] minus [--apply] | ignore
    do $check_layout $r minus A1 [$a1 $a2]
    if ($r | path join src $HOST_B age.sops | path exists) or ($r | path join src $HOST_B secrets.shared.sops.json | path exists) { fail "a removed host keeps its key or copy" }
    if ($r | path join src generated nodes 250-apps-swarm | path exists) { fail "a removed worker keeps its folder" }
    if (hash-of ($r | path join src $HOST_A secrets.sops.json)) != $a_before { fail "removing hosts rewrote a's file" }
    do $sync $r A1 [$a1 $a2] base [--apply] | ignore
    do $check_layout $r base A1 [$a1 $a2]
    ok "8 removed hosts lose key, copy and folder, the app's file its reader; others byte-identical; they come back"

    # 9: refusals leave the tree as it was
    do $refuses $r "101-internal-b reads nope, which nothing declares" A1 [$a1 $a2] problem [--apply]
    do $refuses $r "vault2 in src/secrets/shared.sops.json" A1 [$a1 $a2] renamed [--apply]
    do $refuses $r "is not an admin recipient" A1 [$a2 $a3] base [--apply]
    let router_pub = $r | path join src $ROUTER age.pub
    cp $router_pub ($t | path join pub.saved)
    $"($a3)\n" | save --force $router_pub
    do $refuses $r $"($ROUTER)/age.pub is not the public half" A1 [$a1 $a2] base [--apply]
    cp ($t | path join pub.saved) $router_pub
    ok "9 refused, nothing written: an undeclared read, a guarded secret without its value, a run locking its own key out, a foreign age.pub"

    # 10: rotating the admin key, A1 out and A3 in
    let history = $t | path join history
    cp -r ($r | path join src) $history
    do $sync $r A1 [$a1 $a2 $a3] base [--apply] | ignore
    do $check_layout $r base A1 [$a1 $a2 $a3]
    let a3_key = do $key_file A3
    for c in ($base_plan.hosts | columns) {
        let stored = dec $a3_key ($r | path join src ($base_plan.hosts | get $c | get home) age.sops)
        if $stored != (open --raw ($t | path join $"($c).key")) { fail $"adding an admin renewed ($c)'s key" }
        cp ($t | path join $"($c).key") ($t | path join $"($c).old.key")
    }
    do $sync $r A3 [$a2 $a3] base [--apply] | ignore
    do $check_layout $r base A3 [$a2 $a3]
    for c in ($base_plan.hosts | columns) {
        if (open --raw ($t | path join $"($c).key")) == (open --raw ($t | path join $"($c).old.key")) { fail $"removing A1 kept ($c)'s key" }
        for file in (reads-of $base_plan $c) {
            if (opens ($t | path join $"($c).old.key") ($r | path join src $file)) { fail $"($c)'s old key opens ($file)" }
        }
    }
    for file in ($base_plan.files | columns) { if (opens $a1_key ($r | path join src $file)) { fail $"A1 opens ($file) after its removal" } }
    if (dec $a3_key ($r | path join src $CAT) | from json | sort) != (dec $a1_key ($history | path join $CAT) | from json | sort) { fail "the rotation changed values" }
    for file in [$CAT $"($HOST_A)/age.sops" $"($HOST_A)/secrets.sops.json"] {
        # the same name, so sops reads the splice in the file's own format
        let spliced = $t | path join $"spliced-($file | path basename)"
        let old_stanza = open --raw ($history | path join $file) | from json | get sops.age | where recipient == $a1
        open --raw ($r | path join src $file) | from json | update sops.age { append $old_stanza } | to json | save --force $spliced
        if (opens $a1_key $spliced) { fail $"A1's old stanza spliced onto the new ($file) decrypts it: the data key was not renewed" }
    }
    ok "10 adding an admin re-encrypts and keeps host keys; removing A1 re-encrypts without it, renews every host key, the splice fails"

    # 11: an injected sops failure loses no value and leaves every file whole; a rerun converges
    let shim = $t | path join shim
    mkdir $shim
    let real_sops = which sops | get 0.path
    ([
        $"#!($nu.current-exe) --no-config-file"
        "# fails the SOPS_FAIL_AT-th encrypt of the run"
        "def --wrapped main [...args: string] {"
        "    if \"--encrypt\" in $args {"
        "        let n = (open --raw $env.SOPS_FAIL_COUNTER | str trim | into int) + 1"
        "        $n | save --force $env.SOPS_FAIL_COUNTER"
        "        if ($n | into string) == $env.SOPS_FAIL_AT { print -e $\"injected sops failure at encrypt ($n)\"; exit 1 }"
        "    }"
        $"    exec ($real_sops) ...$args"
        "}"
    ] | str join "\n") | save ($shim | path join sops)
    ^chmod 755 ($shim | path join sops)
    let counter = $t | path join counter
    let shimmed = {|at: int| {PATH: ([$shim] ++ $env.PATH), SOPS_FAIL_COUNTER: $counter, SOPS_FAIL_AT: ($at | into string)} }
    let moved_plan = do $plan_of moved
    # every value of a repo, as "<name> <value>" over all values files
    let values_of = {|dir: path|
        glob ($dir | path join src "**" secrets.sops.json) | append ($dir | path join src $CAT) | uniq | where { path exists }
            | each {|f| dec $a3_key $f | from json | items {|k, v| $"($k) ($v)" } } | flatten | uniq | sort
    }
    # contents and recipient shape per file, host keys abstracted to the configuration owning them
    let state_of = {|dir: path|
        let names = $moved_plan.hosts | columns | reduce --fold ({} | insert $a1 A1 | insert $a2 A2 | insert $a3 A3) {|c, acc|
            $acc | upsert (open --raw ($dir | path join src ($moved_plan.hosts | get $c | get home) age.pub) | str trim) $c
        }
        $moved_plan.files | columns | each {|file|
            let path = $dir | path join src $file
            let owners = recipients $path | each {|rec| $names | get --optional $rec | default "?" } | sort | str join ' '
            let content = if ($file | str ends-with age.sops) { "" } else { dec $a3_key $path | from json | sort | to json --raw }
            $"($file) ($owners)\n($content)"
        } | str join "\n"
    }
    # the faulted run: a move plus A1 back in, unlocked with A3
    let fault_base = $t | path join fault-base
    cp -r $r $fault_base
    let reference = $t | path join reference
    cp -r $fault_base $reference
    "0" | save --force $counter
    let ref_run = do $sync_run $reference A3 [$a1 $a2 $a3] moved [--apply] (do $shimmed 0)
    if $ref_run.exit_code != 0 { fail $"the reference run failed: ($ref_run.stderr)" }
    let encrypts = open --raw $counter | str trim | into int
    if $encrypts <= 1 { fail $"the reference run encrypted ($encrypts) file\(s\)" }
    let reference_state = do $state_of $reference
    let base_values = do $values_of $fault_base
    mut rng = $seed mod $LCG_MODULUS
    for trial in 1..$FAULT_TRIALS {
        $rng = lcg-next $rng
        let at = (lcg-draw $rng $encrypts) + 1
        let f = $t | path join $"fault-($trial)"
        cp -r $fault_base $f
        "0" | save --force $counter
        let faulted = do $sync_run $f A3 [$a1 $a2 $a3] moved [--apply] (do $shimmed $at)
        if $faulted.exit_code == 0 { fail $"trial ($trial): a failed sops encrypt ($at) went unnoticed" }
        let sops_files = glob ($f | path join src "**" "*.sops.json") | append (glob ($f | path join src "**" age.sops))
        for file in $sops_files { if not (opens $a3_key $file) { fail $"trial ($trial) \(encrypt ($at)\): ($file) is neither old nor whole" } }
        let lost = $base_values | where $it not-in (do $values_of $f)
        if ($lost | is-not-empty) { fail $"trial ($trial) \(encrypt ($at)\): a value was lost" }
        if (glob ($f | path join "**" ".sops-encrypt.*") | is-not-empty) { fail $"trial ($trial): a temp file stayed behind" }
        do $sync $f A3 [$a1 $a2 $a3] moved [--apply] | ignore
        if (do $state_of $f) != $reference_state { fail $"trial ($trial) \(encrypt ($at)\): the rerun did not converge" }
        print $"  trial ($trial): encrypt ($at) of ($encrypts) failed: every file whole, no value lost, the rerun converged"
    }
    ok $"11 ($FAULT_TRIALS) injected sops failures: safe, and a rerun converges"

    # 12: the real plan
    let rr = $t | path join real
    do $repo_create $rr
    do $sync $rr A1 [$a1 $a2] real [--apply --generate-guarded] | ignore
    let real_plan = do $plan_of real
    let real_configs = $real_plan.hosts | columns
    let real_files = $real_plan.files | columns
    for c in $real_configs { do $host_key $rr $c $real_plan ($t | path join $"real-($c).key") A1 }
    for file in ($real_files | where { not ($in | str ends-with age.sops) }) {
        if (dec $a1_key ($rr | path join src $file) | from json | columns | sort) != (names-of $real_plan $file) { fail $"real ($file) holds other names than declared" }
    }
    for _ in 1..$REAL_PAIRS {
        $rng = lcg-next $rng
        let c = $real_configs | get (lcg-draw $rng ($real_configs | length))
        $rng = lcg-next $rng
        let file = $real_files | get (lcg-draw $rng ($real_files | length))
        if (opens ($t | path join $"real-($c).key") ($rr | path join src $file)) and $file not-in (reads-of $real_plan $c) { fail $"real ($c)'s key opens ($file)" }
    }
    let before = tree-hash $rr
    do $sync $rr A1 [$a1 $a2] real [--apply] | ignore
    if (tree-hash $rr) != $before { fail "a second run over the real plan changed bytes" }
    ok $"12 the real plan \(($real_configs | length) configurations, ($real_files | length) files\): contents, sampled isolation, idempotence"

    print "secrets-sync: all assertions hold"
}
