# the repo's formatter, `nix fmt`: every file under the given paths (the whole repo by default) through its
# language's formatter; nixfmt, ruff, gofmt and terraform come on PATH from formatter.nix

const LINE_WIDTH = 120
const FORMATTERS = {
    nix: [nixfmt $"--width=($LINE_WIDTH)"]
    py: [ruff format --no-cache --quiet $"--line-length=($LINE_WIDTH)"]
    go: [gofmt -w]
    tf: [terraform fmt]
}

def files-under [path: path]: nothing -> list<path> {
    if ($path | path type) == file { return [$path] }
    # a work tree lists what git tracks or would track; a store copy (the format check) is nothing else
    if (git -C $path rev-parse --is-inside-work-tree | complete).exit_code == 0 {
        git -C $path ls-files --cached --others --exclude-standard -z
        | split row (char nul) | compact --empty | each {|file| $path | path join $file } | where ($it | path exists)
    } else {
        glob ($path | path join '**' '*') --no-dir
    }
}

def main [...paths: path]: nothing -> nothing {
    let roots = if ($paths | is-empty) { [(git rev-parse --show-toplevel)] } else { $paths | path expand }
    let files = $roots | each {|root| files-under $root } | flatten | uniq
    for language in ($FORMATTERS | columns) {
        let matching = $files | where ($it | path parse | get extension) == $language
        if ($matching | is-empty) { continue }
        let command = $FORMATTERS | get $language
        run-external ($command | first) ...($command | skip 1) ...$matching
    }
}
