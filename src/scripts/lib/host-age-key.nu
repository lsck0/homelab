#!/usr/bin/env -S nu --no-config-file --stdin
# on a guest, with its own age key on stdin: host-age-key.nu push|settle <key file>
#   push    a key that differs goes ahead of the identities the file holds, so the running system and the next boot
#           still decrypt until a switch takes the new one; prints "changed" when it did
#   settle  after a switch that decrypted with it, the file holds that key alone
# sync.nu runs it around each deploy's switch.

def key-file-write [file: path, text: string]: nothing -> nothing {
    let new = $"($file).new"
    ^install -m 600 /dev/null $new
    $text | save --append $new
    mv --force $new $file
}

def main [action: string, key_file: path]: string -> nothing {
    let key = $in
    if $action not-in [push settle] {
        print -e "usage: host-age-key.nu push|settle <key file>"
        exit 2
    }
    ^install -d -m 700 ($key_file | path dirname)
    if $action == "settle" {
        key-file-write $key_file $key
        return
    }
    let held = if ($key_file | path exists) { open --raw $key_file } else { "" }
    if $held == $key { return }
    let new_lines = $key | lines
    let kept = $held | lines | where $it not-in $new_lines
    key-file-write $key_file ($new_lines ++ $kept | each { $"($in)\n" } | str join)
    print changed
}
