# the proton fronts' shared prelude (proton-mirror.nu, proton-bisync.nu): the source guard and the helpers both use

# the cli prints its error under a row of '=' after a source excerpt: the tail holds the cause
const ERROR_CHARS = 400

def die [message: string]: nothing -> nothing {
    print --stderr $message
    exit 1
}

# runs a command with its output streaming to the journal: its exit status
def --wrapped status-of [...command: string]: nothing -> int {
    try { run-external ...$command; 0 } catch {|e| $e.exit_code? | default 1 }
}

def file-filled [file: path]: nothing -> bool {
    ($file | path type) == file and (ls $file | get 0.size) > 0b
}

# the last ERROR_CHARS of a cli error, banner rows dropped, on one line
def error-short [text: string]: nothing -> string {
    $text | lines | str trim | where {|line| ($line | str replace --all --regex '[=\-\s]' '') != "" } | str join " "
    | str replace --all --regex '\s+' ' ' | str substring (-1 * $ERROR_CHARS)..
}

# fails, saying why, for a folder that is missing, lacks its marker (unmounted or wiped) or holds nothing beside it:
# such a folder must never read as one whose every file was deleted
def source-guard [dir: path, marker: string]: nothing -> nothing {
    if not ($dir | path join $marker | path exists) {
        die $"no ($marker) in ($dir): missing, unmounted or wiped; refusing to sync"
    }
    let beside = ls --all $dir | where {|entry| ($entry.name | path basename) != ($marker | path basename) }
    if ($beside | is-empty) {
        die $"($dir) holds nothing beside ($marker); refusing to sync"
    }
}
