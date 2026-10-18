# deletes the proton cli's events.lock when it does not parse: run only under the proton lock, so no cli holds it
#
# workaround: cli 0.8.0 reads <cache dir>/events.lock as json on every call (src/events/lock.ts) and fails every call
# on a torn one, which an unclean shutdown leaves (NUL bytes). The file is an advisory lock only, so deleting it is
# safe. Delete this once a cli release tolerates a torn lock.

def main [cache_dir: path]: nothing -> nothing {
    let lock = $cache_dir | path join events.lock
    if ($lock | path type) != file { return }
    let text = try { open --raw $lock | into binary | decode utf-8 } catch { "" }
    # a json object, as the cli's JSON.parse wants it: without --strict, from json takes bare words, comments and
    # trailing commas
    let parsed = try { ($text | from json --strict | describe) =~ '^record' } catch { false }
    if not $parsed {
        print $"($lock) is torn \(an unclean shutdown\): deleted, the cli writes a new one"
        rm --force $lock
    }
}
