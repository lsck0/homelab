# the admin recipients, the layout's plan (modules/secrets.nix), one secret by name, and the admin age key
#
# Every path of the plan is relative to src/. The caller sets SOPS_AGE_KEY_FILE.

use tools.nu [die run-text tools-require]

const ATTR = "legacyPackages.x86_64-linux.secrets"
const RECIPIENT_PATTERN = '^age1[0-9a-z]+$'
const AGE_KEY_LINE = '^AGE-SECRET-KEY-'
const NIX_FEATURES = [--extra-experimental-features "nix-command flakes"]
# the layout's names (modules/secrets.nix): the folders holding host homes, and the files a home holds
export const SECRETS_HOME_DIRS = [instances/core instances/preconfigured instances/custom generated/nodes]
export const SECRETS_CATALOG_FILE = "secrets/shared.sops.json"
export const SECRETS_TFVARS_FILE = "terraform/terraform.tfvars.sops.json"
export const SECRETS_VALUES_NAME = "secrets.sops.json"
export const SECRETS_SHARED_NAME = "secrets.shared.sops.json"
export const SECRETS_KEY_NAME = "age.sops"
export const SECRETS_PUB_NAME = "age.pub"

# the dotfiles checkout; its git-crypt secrets hold the admin age key (age.txt), the deploy ssh key and the ntfy token
export def secrets-dotfiles []: nothing -> path {
    $env.DOTFILES? | default ($env.HOME | path join projects arch-dotfiles)
}

export def secrets-dotfiles-dir []: nothing -> path {
    $env.DOTFILES_SECRETS? | default (secrets-dotfiles | path join secrets)
}

# the private key lines of an age identity file; none while git-crypt holds it locked
export def secrets-age-key-lines [file: path]: nothing -> list<string> {
    if not ($file | path exists) { return [] }
    try { open --raw $file | lines | where $it =~ $AGE_KEY_LINE } catch { [] }
}

# an age key's public half
export def secrets-age-recipient [key: string]: nothing -> string {
    $key | run-text age-keygen -y
}

# src/secrets/admins.txt in its order, or SECRETS_ADMIN_RECIPIENTS (space separated) in its place; dies unless the
# run's key is one
export def secrets-admins-load [src: path]: nothing -> list<string> {
    let file = $src | path join secrets admins.txt
    let recipients = if ($env.SECRETS_ADMIN_RECIPIENTS? | is-not-empty) {
        $env.SECRETS_ADMIN_RECIPIENTS | split row --regex '\s+' | where $it != ""
    } else {
        open --raw $file | lines | each { str replace --regex '#.*' '' | str replace --all --regex '\s' '' } | where $it != ""
    }
    if ($recipients | is-empty) { die $"no admin recipient in ($file)" }
    for r in $recipients {
        if $r !~ $RECIPIENT_PATTERN { die $"($r) is no age recipient \(($file)\)" }
        # bech32 data never holds a 1, so the part before the last 1 is the kind: age1yubikey1... needs age-plugin-yubikey
        let kind = $r | str replace --regex '1[^1]*$' ''
        if $kind != "age" { tools-require $"age-plugin-($kind | str replace 'age1' '')" }
    }
    if ($recipients | uniq | length) != ($recipients | length) { die $"an admin recipient is listed twice in ($file)" }

    # a run that leaves its own key out of the admin set would lock the owner out of every file it writes
    let key_file = $env.SOPS_AGE_KEY_FILE
    let keys = secrets-age-key-lines $key_file
    if ($keys | is-empty) { die $"admin age key not readable at ($key_file)" }
    let unlocking = $keys | each { secrets-age-recipient $in }
    if ($unlocking | all { $in not-in $recipients }) {
        die ([
            $"the key unlocking this run \(($key_file): ($unlocking | str join ' ')\) is not an admin recipient."
            "       Rotate in two runs: add the new recipient and run with the old key, then unlock with the new key and"
            "       remove the old recipient (FEATURES.md, \"Secrets\")."
        ] | str join "\n")
    }
    $recipients
}

# {secrets, hosts, files, problems} as modules/secrets.nix plans it, from <file> or the flake
export def secrets-plan-load [src: path, file?: path]: nothing -> record {
    let plan = if $file != null { open --raw $file | from json } else {
        print ">>> Secrets: evaluating which host reads which secret..."
        let printed = ^nix eval --json ...$NIX_FEATURES $"($src)#($ATTR).plan"
        $printed | from json
    }
    let shape = [secrets hosts files] | all {|k| ($plan | get --optional $k | describe) =~ '^record' }
    if not ($shape and ($plan.problems? | describe) =~ '^(list|table)') {
        die "the secrets plan is not {secrets, hosts, files, problems}"
    }
    if ($plan.problems | is-not-empty) {
        die (["the lab's secrets are inconsistent:"] ++ $plan.problems | str join "\n")
    }
    $plan
}

export def secrets-declared-load [src: path]: nothing -> record {
    let printed = ^nix eval --json ...$NIX_FEATURES $"($src)#($ATTR).declared"
    $printed | from json
}

# the file holding it, relative to src/
def file-of [src: path, name: string]: nothing -> string {
    ^nix eval --raw ...$NIX_FEATURES $"($src)#($ATTR).declared.\"($name)\".file"
}

export def secrets-get [src: path, name: string]: nothing -> string {
    let value = ^sops --decrypt --extract $"[\"($name)\"]" ($src | path join (file-of $src $name))
    $value | str trim --right --char "\n"
}

# the value reaches sops on stdin, never argv
export def secrets-set [src: path, name: string, value: string]: nothing -> nothing {
    $value | to json | ^sops set --value-stdin ($src | path join (file-of $src $name)) $"[\"($name)\"]"
}

# <link> -> the dotfiles' age.txt, unless <link> is a file of its own
export def secrets-age-key-link [link: path]: nothing -> nothing {
    if ($link | path exists) and ($link | path type) != symlink { return }
    mkdir ($link | path dirname)
    ^ln -sfn (secrets-dotfiles-dir | path join age.txt) $link
}

# the admin key, linked and unlocked: locked, the dotfiles' YubiKey unlock runs once
export def --env secrets-age-key-ready [link: path]: nothing -> nothing {
    secrets-age-key-link $link
    if (secrets-age-key-lines $link | is-empty) {
        print ">>> dotfiles secrets locked: touch the YubiKey"
        # the workstation's nu: dot.nu does not parse on the flake's older one, first on PATH in the dev shell
        let system_nu = which --all nu | where { not ($in.path | str starts-with /nix/store) } | get --optional 0.path | default /usr/bin/nu
        # a failed unlock is reported by the check below
        try { ^$system_nu --no-config-file (secrets-dotfiles | path join scripts dot.nu) secrets unlock }
        if (secrets-age-key-lines $link | is-empty) { die $"($link) is not an age key, unlock the dotfiles secrets: dot secrets unlock" }
    }
    $env.SOPS_AGE_KEY_FILE = $link
}

# <plaintext> | secrets-encrypt <target>: encrypted by the .sops.yaml rule its path matches, renamed into place only
# once it decrypts with this run's key; a *.json target is a json document, any other (age.sops) a binary blob.
# Every call encrypts afresh with a new data key: the admin-key rotation (secrets-sync.nu) depends on it.
export def secrets-encrypt [root: path, target: path]: any -> nothing {
    let plain = $in
    let target_abs = $target | path expand --no-symlink
    let target_rel = try { $target_abs | path relative-to $root } catch { die --misuse $"($target) is outside the repo ($root)." }
    let type = if ($target_rel | str ends-with ".json") { "json" } else { "binary" }
    let tmp = mktemp --tmpdir-path ($target_abs | path dirname) .sops-encrypt.XXXXXX
    ^chmod 600 $tmp
    # --filename-override picks the creation rule (recipients) of the target, not of /dev/stdin; the rules match
    # repo-relative paths
    let encrypted = do { cd $root; $plain | ^sops --encrypt --filename-override $target_rel --input-type $type --output-type $type /dev/stdin } | complete
    if $encrypted.exit_code != 0 {
        rm --force $tmp
        die $"($target): sops did not encrypt: ($encrypted.stderr | str trim)"
    }
    $encrypted.stdout | save --force $tmp
    let status = do { ^sops filestatus --input-type $type $tmp } | complete
    if $status.exit_code != 0 or (try { ($status.stdout | from json).encrypted } catch { false }) != true {
        rm --force $tmp
        die $"($target): sops wrote an unencrypted file."
    }
    if (do { ^sops --decrypt --input-type $type --output-type $type $tmp } | complete).exit_code != 0 {
        rm --force $tmp
        die $"($target): the encrypted file does not decrypt with this key."
    }
    mv --force $tmp $target_abs
}
