# textfile-prune <dir> <pattern>...: removes the .prom files of names the previous run recorded in <dir>/.declared and
# none of the patterns covers any more, then records the patterns; a file never recorded is left alone.

const RECORD = ".declared"
const PROM_SUFFIX = '\.prom(\.tmp)?$'
# a name, or a name prefix with * for a runtime part (modules/textfile's textfiles option)
const PATTERN_SHAPE = '^[a-z0-9_-]+\*?$'

def pattern-to-regex [pattern: string]: nothing -> string {
    if $pattern !~ $PATTERN_SHAPE { error make {msg: $"textfile: no textfile pattern: '($pattern)'"} }
    $"^($pattern | str replace '*' '.*')$"
}

def name-matches [name: string, regexes: list<string>]: nothing -> bool {
    $regexes | any {|regex| $name =~ $regex }
}

def record-save [record: path, names: list<string>]: nothing -> nothing {
    $names | each { $in + "\n" } | str join | save --force $"($record).tmp"
    mv --force $"($record).tmp" $record
}

def main [dir: path, ...patterns: string]: nothing -> nothing {
    let record = $dir | path join $RECORD
    let declared = $patterns | each {|p| pattern-to-regex $p }
    mkdir $dir
    let previous = if ($record | path exists) {
        open --raw $record | lines | where $it != "" | each {|p| pattern-to-regex $p }
    } else { [] }

    ls --all $dir | where type != dir | get name | each {|file|
        let name = $file | path basename
        let base = $name | str replace --regex $PROM_SUFFIX ""
        if $base != $name and (name-matches $base $previous) and not (name-matches $base $declared) {
            rm --force $file
            print $"textfile: removed ($file), no unit of this host writes it any more"
        }
    } | ignore

    record-save $record $patterns
}
