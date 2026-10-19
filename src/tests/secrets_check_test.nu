# the plaintext guard as the pre-commit hook runs it: each case stages files in a scratch repo, commits, and expects the
# commit refused (HEAD unchanged, stderr naming the path or key) or accepted (HEAD advanced). Every refusal has an
# accepted control of the same shape. Throwaway age key, no network.
#
# usage: nu secrets_check_test.nu <dir with .githooks/ and src/>

const TFVARS = "src/terraform/terraform.tfvars.sops.json"
const H = "src/instances/preconfigured/1-internal-x"
const TOKEN_SECRET = "0b5e2f1c-7d4a-4e9b-a3c6-1f8d2e7b9a40"
# fixture values: a generated secret, a multi-line key, one too short to scan
const LLDAP = "4f2c9a7e1b3d5f60a8c2e4b6d8f0a1c3e5b7d9f1a3c5e7b9"
# an openssh key: its first body line is the format header every ed25519 key shares, the second is its own
const PEM_HEADER = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW"
const PEM_BODY = "QyNTUxOQAAACBf3x9Qm1x7cXJ0dGVzdC1maXh0dXJlLW5vdC1hLXJlYWwta2V5AAAA"
const SHORT = "abc"
const YUBIKEY_IDENTITY_BODY_CHARS = 27

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

# armor and identities assembled at run time: written out, this file would match the patterns it tests
def armor [edge: string, kind: string]: nothing -> string { $"-----($edge) ($kind)-----" }

def --wrapped git-in [dir: path, ...args: string]: nothing -> string {
    let printed = ^git -C $dir ...$args
    $printed | str trim
}

def encrypt [script_root: path, target: string]: string -> nothing {
    $in | ^nu --no-config-file --stdin ($script_root | path join src scripts sops-encrypt.nu) $target
}

def main [fixture: path]: nothing -> nothing {
    let t = mktemp --directory
    cd $t
    ^age-keygen -o ($t | path join admin.key) e> /dev/null
    ^age-keygen -o ($t | path join host.key) e> /dev/null
    let admin = ^age-keygen -y ($t | path join admin.key) | str trim
    let host = ^age-keygen -y ($t | path join host.key) | str trim
    let host_key_line = open --raw ($t | path join host.key) | lines | where { str starts-with AGE-SECRET-KEY } | first
    let admin_key_line = open --raw ($t | path join admin.key) | lines | where { str starts-with AGE-SECRET-KEY } | first
    $env.SOPS_AGE_KEY_FILE = $t | path join admin.key
    let yubikey_identity = $"AGE-PLUGIN-YUBIKEY-1('' | fill --character Q --width $YUBIKEY_IDENTITY_BODY_CHARS)"

    let b = $t | path join base
    mkdir ($b | path join $H) ($b | path join src secrets) ($b | path join src terraform)
    # coreutils: nu's cp keeps the store's read-only modes on the directories it creates, then cannot fill them
    ^cp -r ($fixture | path join .githooks) $b
    ^cp -r ($fixture | path join src scripts) ($b | path join src)
    ^chmod -R u+w $b
    # the real rule shapes (secrets-sync.nu): the shared values admin-only, a host's key admin-only, its own values to it
    ([
        "creation_rules:"
        "  - path_regex: src/secrets/shared\\.sops\\.json$" $"    age: ($admin)"
        $"  - path_regex: ($H)/age\\.sops$" $"    age: ($admin)"
        $"  - path_regex: ($H)/secrets\\.sops\\.json$" $"    age: ($admin),($host)"
        "  - path_regex: src/terraform/terraform\\.tfvars\\.sops\\.json$" $"    age: ($admin)"
    ] | str join "\n") + "\n" | save ($b | path join .sops.yaml)
    # what the guard otherwise evaluates from the flake: where each secret lives and its kind
    let host_file = $H | str replace "src/" "" | path join secrets.sops.json
    {
        "app-deploy-key": {kind: manual, file: secrets/shared.sops.json}
        "proxmox-user": {kind: public, file: secrets/shared.sops.json}
        "short-one": {kind: manual, file: secrets/shared.sops.json}
        "lldap-admin-password": {kind: "hex:24", file: $host_file}
        "proxmox_api_token_secret": {kind: manual, file: ($TFVARS | str replace "src/" "")}
        "proxmox_datastore": {kind: public, file: ($TFVARS | str replace "src/" "")}
    } | to json | save ($t | path join declared.json)
    $env.SECRETS_DECLARED = $t | path join declared.json
    let ssh_begin = armor BEGIN "OPENSSH PRIVATE KEY"
    let ssh_end = armor END "OPENSSH PRIVATE KEY"
    {
        "app-deploy-key": $"($ssh_begin)\n($PEM_HEADER)\n($PEM_BODY)\n($ssh_end)\n"
        "proxmox-user": "homepage@pve!homepage"
        "short-one": $SHORT
    } | to json | encrypt $b ($b | path join src secrets shared.sops.json)
    {"lldap-admin-password": $LLDAP} | to json | encrypt $b ($b | path join $H secrets.sops.json)
    $"($host_key_line)\n" | encrypt $b ($b | path join $H age.sops)
    {proxmox_api_token_secret: $TOKEN_SECRET, proxmox_datastore: local-lvm} | to json | encrypt $b ($b | path join $TFVARS)
    "hello\n" | save ($b | path join README.md)
    ^git -C $b init -q
    ^git -C $b config user.name t
    ^git -C $b config user.email t@t
    ^git -C $b config core.hooksPath .githooks
    ^git -C $b add -A
    ^git -C $b commit -qm base --no-verify

    # one case: a fresh copy, the setup stages files, a commit decides
    mut cases = 0
    let check = {|n: int, name: string, expect: string, says: string, setup: closure, settings: record|
        let r = $t | path join $"case-($n)"
        cp -r $b $r
        do { cd $r; do $setup $r }
        let head = git-in $r rev-parse HEAD
        let out = with-env $settings { do { cd $r; ^git commit -qm $"case ($name)" } | complete }
        let advanced = (git-in $r rev-parse HEAD) != $head
        if $expect == "accepted" {
            if $out.exit_code != 0 or not $advanced { fail $"($name): expected accepted, got rc=($out.exit_code): ($out.stdout)($out.stderr)" }
        } else {
            if $out.exit_code == 0 or $advanced { fail $"($name): expected refused, got rc=($out.exit_code)" }
            if not ($"($out.stdout)($out.stderr)" | str contains $says) { fail $"($name): the refusal does not say '($says)': ($out.stdout)($out.stderr)" }
            if ($"($out.stdout)($out.stderr)" | str contains $LLDAP) { fail $"($name): the refusal prints a secret value" }
        }
        print $"ok: ($name) -> ($expect)"
    }
    let write = {|file: string, content: string| $content | save --force $file; ^git add -- $file }

    let cases_table = [
        [name expect says setup];
        ["encrypted host file" accepted "" {|r| {"lldap-admin-password": "changed-value-x"} | to json | encrypt $r $"($H)/secrets.sops.json"; ^git add $"($H)/secrets.sops.json" }]
        ["plaintext host file" refused $"($H)/secrets.sops.json is staged unencrypted" {|r| do $write $"($H)/secrets.sops.json" '{"lldap-admin-password": "plain-value-123"}' }]
        ["plaintext shared values" refused "src/secrets/shared.sops.json is staged unencrypted" {|r| do $write src/secrets/shared.sops.json '{"proxmox-user": "x"}' }]
        ["plaintext host key" refused $"($H)/age.sops is staged unencrypted" {|r| do $write $"($H)/age.sops" $"($host_key_line)\n" }]
        ["encrypted host key" accepted "" {|r| $"($admin_key_line)\n" | encrypt $r $"($H)/age.sops"; ^git add $"($H)/age.sops" }]
        ["plaintext staged, worktree encrypted" refused $"($H)/secrets.sops.json" {|r|
            do $write $"($H)/secrets.sops.json" '{"a": "plain-value-staged"}'
            '{"a": "plain-value-staged"}' | encrypt $r $"($H)/secrets.sops.json"
        }]
        ["plaintext value beside ciphertext" refused "plaintext value beside its ciphertext" {|r|
            do $write $"($H)/secrets.sops.json" (open --raw $"($H)/secrets.sops.json" | from json | insert added plaintext-beside-ciphertext | to json)
        }]
        ["sops metadata stripped" refused $"($H)/secrets.sops.json" {|r| do $write $"($H)/secrets.sops.json" (open --raw $"($H)/secrets.sops.json" | from json | reject sops | to json) }]
        ["non-json under a rule says why" refused $"($H)/secrets.sops.json is staged unencrypted" {|r| do $write $"($H)/secrets.sops.json" "a: plain\n" }]
        ["host file without a .sops.yaml rule" refused "src/generated/nodes/250-apps-swarm/secrets.shared.sops.json" {|r|
            mkdir src/generated/nodes/250-apps-swarm
            do $write src/generated/nodes/250-apps-swarm/secrets.shared.sops.json '{"x": "plain-value-unruled"}'
        }]
        ["decrypted .bak beside the host files" refused $"($H)/secrets.sops.json.bak" {|r| do $write $"($H)/secrets.sops.json.bak" (^sops -d $"($H)/secrets.sops.json") }]
        ["staged deletion of a secrets file" accepted "" {|r| ^git rm -q $"($H)/secrets.sops.json" }]

        # key material and decrypted copies anywhere
        ["age private key in notes.txt" refused "notes.txt contains private key material" {|r| do $write notes.txt (open --raw ($t | path join host.key)) }]
        ["openssh private key" refused "id_ed25519 contains private key material" {|r| do $write id_ed25519 $"($ssh_begin)\nAAAA\n($ssh_end)\n" }]
        ["yubikey identity" refused "identity.txt contains private key material" {|r| do $write identity.txt $"($yubikey_identity)\n" }]
        ["pgp private key" refused "signing.asc contains private key material" {|r| do $write signing.asc $"(armor BEGIN 'PGP PRIVATE KEY BLOCK')\n\nxx\n" }]
        ["key inside a binary file" refused "blob.bin contains private key material" {|r|
            let zeros = 1..64 | each { 0x[00] } | bytes collect
            bytes build $zeros (open --raw ($t | path join host.key) | into binary) $zeros | save --force blob.bin
            ^git add blob.bin
        }]
        ["key in a path with a space and a newline" refused "contains private key material" {|r|
            open --raw ($t | path join host.key) | save --force "odd name\nwith newline.txt"
            ^git add -A
        }]
        ["a decrypted copy by name" refused "secrets.dec.json is named like a decrypted copy" {|r| do $write secrets.dec.json '{"nothing": "secret here"}' }]
        ["a public age recipient" accepted "" {|r| do $write recipient.txt $"($host)\n" }]

        # secret values from every values file
        ["a secret value in notes.txt" refused "notes.txt contains the value of lldap-admin-password" {|r| do $write notes.txt $"password: ($LLDAP)\n" }]
        ["one line of a multi-line secret" refused "dump.txt contains the value of app-deploy-key" {|r| do $write dump.txt $"key body ($PEM_BODY)\n" }]
        ["the format header every key shares" accepted "" {|r| do $write format.txt $"any ed25519 key starts ($PEM_HEADER)\n" }]
        ["a public value (an id) in code" accepted "" {|r| do $write init.conf "user = \"homepage@pve!homepage\"\n" }]
        ["the proxmox api token from the terraform vars" refused "main.tf contains the value of proxmox_api_token_secret" {|r| do $write main.tf $"token = ($TOKEN_SECRET)\n" }]
        ["a public terraform var in code" accepted "" {|r| do $write main.tf "datastore = \"local-lvm\"\n" }]
        ["a value below the scan length" accepted "" {|r| do $write short.txt "abc def\n" }]

        # the rules themselves, and a clean commit
        [".sops.yaml without any path_regex" refused "no path_regex in .sops.yaml" {|r|
            "creation_rules: []\n" | save --force .sops.yaml
            "x\n" | save --force a.txt
            ^git add .sops.yaml a.txt
        }]
        ["a clean commit" accepted "" {|r| "more\n" | save --append README.md; ^git add README.md }]
    ]
    for c in $cases_table {
        $cases += 1
        do $check $cases $c.name $c.expect $c.says $c.setup {}
    }
    $cases += 1
    do $check $cases "a secret value, no admin key (warns)" accepted "" {|r| do $write notes.txt $"password: ($LLDAP)\n" } {SOPS_AGE_KEY_FILE: /nonexistent}

    # sync.nu's mode: the value scan is mandatory
    let r = $t | path join require
    cp -r $b $r
    do { cd $r; do $write notes.txt $"password: ($LLDAP)\n" }
    let guard = {|args: list<string>| do { cd $r; ^nu --no-config-file src/scripts/secrets-check.nu ...$args } | complete }
    let out = with-env {SOPS_AGE_KEY_FILE: /nonexistent} { do $guard [--require-values] }
    if $out.exit_code != 1 or not ($out.stderr | str contains "the value scan is required") { fail $"--require-values without a key: rc=($out.exit_code) ($out.stderr)" }
    print "ok: --require-values without the admin key -> refused"
    let out = do $guard [--require-values]
    if $out.exit_code != 1 or not ($out.stderr | str contains "notes.txt contains the value of lldap-admin-password") { fail $"--require-values with a key: rc=($out.exit_code)" }
    print "ok: --require-values with the admin key -> refused naming the key"
    let out = do $guard [--aply]
    if $out.exit_code != 2 { fail $"an unknown flag gave rc=($out.exit_code)" }
    print "ok: an unknown flag -> usage, rc 2"

    print $"secrets-check: ($cases) cases hold"
}
