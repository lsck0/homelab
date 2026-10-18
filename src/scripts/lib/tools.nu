# what every script of the repo shares: its tools checked once at startup, its way to stop, and quoting for ssh

# a script names what it needs before it does any work, so a missing tool stops it with the fix
export def tools-require [...tools: string]: nothing -> nothing {
    let absent = $tools | where { (which $in | is-empty) }
    if ($absent | is-not-empty) {
        die $"missing ($absent | str join ' '): run inside the dev shell, `nix develop ./src` from the repo root."
    }
}

# exit 1 with one "ERROR: <why>" line on stderr, 2 with --misuse
export def die [message: string, --misuse]: nothing -> nothing {
    print -e $"ERROR: ($message)"
    exit (if $misuse { 2 } else { 1 })
}

export def warn [message: string]: nothing -> nothing {
    print -e $"WARNING: ($message)"
}

# one word for a remote sh, whatever it holds: ssh joins its arguments into one command line
export def sh-quote [word: string]: nothing -> string {
    $"'($word | str replace --all "'" "'\\''")'"
}

# an external's stdout, trimmed; its failure raises, which a pipe straight into another command hides on nu 0.108
export def --wrapped run-text [...argv: string]: any -> string {
    let printed = $in | ^$argv.0 ...($argv | skip 1)
    $printed | str trim
}
