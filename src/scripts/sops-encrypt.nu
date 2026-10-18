#!/usr/bin/env -S nu --no-config-file --stdin
# <plaintext> | sops-encrypt.nu <target>: <target> encrypted by the .sops.yaml rule its path matches, so plaintext
# never touches the repo; a failed call leaves the target as it was and no temp file behind (lib/secrets.nu)

const ROOT = path self | path dirname | path dirname | path dirname
use lib/secrets.nu [secrets-encrypt]
use lib/tools.nu [tools-require]

def main [target: path]: any -> nothing {
    let plain = $in
    tools-require sops
    $plain | secrets-encrypt $ROOT $target
}
