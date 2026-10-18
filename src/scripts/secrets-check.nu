#!/usr/bin/env -S nu --no-config-file
# refuse a git index that would publish a secret: run by the pre-commit hook, and by sync.nu before it builds and
# before it commits. The repo is public, so a staged secret is one `git push` from being published.
#
# Every staged blob (added, copied, modified, renamed) is checked:
#   - a sops-managed path (a .sops.yaml rule, or SOPS_PATHS whatever .sops.yaml says) must hold a sops file whose every
#     value is encrypted: a plaintext key added next to the ciphertext is refused too
#   - a decrypted copy by name (x.dec.json, x.plain.yaml, x.decrypted) is refused wherever it lies
#   - no blob may contain private key material (age, PEM, YubiKey identities)
#   - no blob may contain a secret value: every line of every value of SECRET_VALUE_MIN_CHARS or more, in every file
#     modules/secrets.nix declares a secret in, except the `public` kind. This needs the admin key and the flake;
#     without either the scan is skipped with a warning, or refused with --require-values (sync.nu).
# Limit: a secret that is in no sops file (a token pasted from a website) is caught only by its shape, if it is key
# material; gitleaks or a review must find the rest.
#
# env: SECRETS_DECLARED  a json file of modules/secrets.nix `declared`, in place of evaluating the flake (tests)

const ROOT = path self | path dirname | path dirname | path dirname
use lib/tools.nu [die tools-require warn]
use lib/secrets.nu [secrets-age-key-lines secrets-declared-load]

# key material that must never be committed in any file, encrypted sops files aside; each written so it cannot match
# its own text, or this file would refuse itself
const SECRET_PATTERNS = 'AGE-SECRET-KEY-1[0-9A-Z]{50,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|-----BEGIN PGP PRIVATE KEY BLOC[K]-----|AGE-PLUGIN-YUBIKEY-1[0-9A-Z]{20,}'
# sops-managed whatever .sops.yaml says: a file of a host the rules do not list yet is still one
const SOPS_PATHS = ['\.sops(\.json)?$']
# names of decrypted copies: sops -d > x.dec.json, x.plain.yaml, x.decrypted
const DECRYPTED_NAME = '\.(dec|plain|decrypted)(\.|$)'
# shorter values (ports, flags, short ids) collide with ordinary text; every generated secret is 32 hex chars or more
const SECRET_VALUE_MIN_CHARS = 8
# lines of a multi-line value that are no secret: PEM and PGP armor
const ARMOR_PREFIX = "-----"
const ARMOR_BEGIN = "-----BEGIN"
const SOPS_CIPHERTEXT_PREFIX = "ENC[AES256_GCM,"

def usage []: nothing -> nothing { die --misuse "usage: secrets-check.nu [--require-values]" }

# every scalar of a json value, at any depth
def scalars [value: any]: nothing -> list {
    match ($value | describe | str replace --regex '<.*' '') {
        "record" => { $value | values | each {|v| scalars $v } | flatten }
        "list" | "table" => { $value | each {|v| scalars $v } | flatten }
        _ => [$value]
    }
}

# sops metadata present and every value (keys aside) ciphertext; sops leaves an empty value (a placeholder to fill)
# as "", which holds nothing
def sops-blob-is-encrypted [blob: binary]: nothing -> bool {
    let doc = try { $blob | decode utf-8 | from json } catch { return false }
    if ($doc | describe) !~ '^record' or ($doc.sops? == null) { return false }
    let tmp = mktemp --tmpdir
    $blob | save --force $tmp
    let status = do { ^sops filestatus --input-type json $tmp } | complete
    rm --force $tmp
    if $status.exit_code != 0 or (try { ($status.stdout | from json).encrypted } catch { false }) != true { return false }
    scalars ($doc | reject sops) | all {|v| ($v | describe) == "string" and ($v == "" or ($v | str starts-with $SOPS_CIPHERTEXT_PREFIX)) }
}

# the value lines to look for, [{key, line}]; none when the scan cannot run, which only --require-values refuses
def values-load [require: bool]: nothing -> list {
    let skip = {|why: string|
        if $require { die $"($why); the value scan is required here." }
        warn $"($why): staged files are not scanned for secret values."
        []
    }
    let declared = if ($env.SECRETS_DECLARED? | is-not-empty) {
        open --raw $env.SECRETS_DECLARED | from json
    } else {
        try { secrets-declared-load ($ROOT | path join src) } catch { null }
    }
    if $declared == null { return (do $skip "the flake does not evaluate, so the secret files are unknown") }
    let key_file = $env.SOPS_AGE_KEY_FILE
    if (secrets-age-key-lines $key_file | is-empty) { return (do $skip $"no admin key at ($key_file)") }
    mut secrets = {}
    for file in ($declared | values | get file | uniq) {
        let path = $ROOT | path join src $file
        if not ($path | path exists) { continue }
        let plain = do { ^sops --decrypt $path } | complete
        if $plain.exit_code != 0 { return (do $skip $"src/($file) does not decrypt with ($key_file)") }
        $secrets = $secrets | merge ($plain.stdout | from json | reject --optional sops)
    }
    $secrets | transpose key value
        | where {|s| ($declared | get --optional $s.key | get --optional kind) != "public" }
        | each {|s|
            let text = if ($s.value | describe) == "string" { $s.value } else { $s.value | to json --raw }
            let lines = $text | split row "\n"
            # the line after BEGIN is the key format header (openssh-key-v1, cipher, kdf), the same in every key of a type
            $lines | enumerate
                | where {|l| $l.index == 0 or not ($lines | get ($l.index - 1) | str starts-with $ARMOR_BEGIN) }
                | each {|l| {key: $s.key, line: ($l.item | str trim)} }
        }
        | flatten
        | where {|v| ($v.line | str length) >= $SECRET_VALUE_MIN_CHARS and not ($v.line | str starts-with $ARMOR_PREFIX) }
}

def --wrapped main [...args: string]: nothing -> nothing {
    let require = match $args { [] => false, ["--require-values"] => true, _ => { usage; false } }
    cd $ROOT
    tools-require git sops
    $env.SOPS_AGE_KEY_FILE = $env.SOPS_AGE_KEY_FILE? | default ($ROOT | path join secrets age.txt)

    let rules = try { open --raw .sops.yaml | lines | parse --regex '^\s*-?\s*path_regex:\s*(?<re>.*)$' | get re } catch { [] }
    if ($rules | is-empty) { die "no path_regex in .sops.yaml: refusing, the rules decide what must be encrypted" }
    let sops_regexes = $rules ++ $SOPS_PATHS

    let values = values-load $require
    let value_bytes = $values | each {|v| $v | insert bytes ($v.line | into binary) }

    let listed = ^git diff --cached --name-only -z --diff-filter=ACMR
    let staged = $listed | split row (char nul) | where $it != ""
    mut problems = 0
    for path in $staged {
        # a staged deletion has no blob to check
        if (do { ^git cat-file -e $":($path)" } | complete).exit_code != 0 { continue }
        let shown = ^git show $":($path)"
        let blob = $shown | into binary
        let refusals = if ($sops_regexes | any {|re| $path =~ $re }) {
            if (sops-blob-is-encrypted $blob) { [] } else {
                [$"($path) is staged unencrypted, or with a plaintext value beside its ciphertext; encrypt it with src/scripts/sops-encrypt.nu"]
            }
        } else {
            let text = $blob | decode utf-8
            let hits = $value_bytes | where {|v| ($blob | bytes index-of $v.bytes) >= 0 } | get --optional key | default [] | uniq | sort
            [
                (if $path =~ $DECRYPTED_NAME { $"($path) is named like a decrypted copy of a sops file" })
                (if $text =~ $SECRET_PATTERNS { $"($path) contains private key material" })
                (if ($hits | is-not-empty) { $"($path) contains the value of ($hits | str join ' ')" })
            ] | compact
        }
        for refusal in $refusals { print -e $"ERROR: ($refusal)" }
        $problems += ($refusals | length)
    }
    if $problems > 0 { die $"($problems) problem\(s\) in staged files would publish secrets; nothing committed." }
}
