# lib/archrepo-list.nu against fixture arch-dotfiles trees. The modules layout: the packages.txt of every module and the
# packages.native.txt beside it, comments, blanks and trailing whitespace dropped, duplicates across modules and
# platforms merged, every platform's EXTRA_PACKAGES joined; nested manifests, flatpacks.txt and nixpkgs.txt left out.
# The generated layout: mirror/packages.txt in place of the modules, the platforms still joined. A bad name, an
# unreadable manifest, a platform file that does not source, an empty set and an old-layout checkout each fail the
# whole list and print nothing: the build prunes what the list misses.
#
# Then the completeness gate as tables: which listed names a sync db does not provide (a name, a provides with its
# version dropped and a group count; a depends and a near name do not; a desc that ends without a blank line still
# reads), and publish's verdict (completeness-check) over served and proposed dbs: a served name the night would lose
# holds it back, a never-built one publishes and stays reported as missing.
#
# usage: nu archrepo_list_test.nu, beside ../lib/archrepo-list.nu and ../lib/archrepo-build.nu

use ../lib/archrepo-build.nu *

const ALL = [base base-devel desktop-only extra-dup libc++ native-only notebook-extra pc-extra rust shared trailing-space]

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def pass [message: string]: nothing -> nothing {
    print $"PASS: ($message)"
}

def list-script []: nothing -> path {
    $env.FILE_PWD | path join .. lib archrepo-list.nu | path expand
}

def list-run [...args: string]: nothing -> record {
    do { ^$nu.current-exe --no-config-file (list-script) ...$args } | complete
}

def write-lines [file: path, lines: list<string>]: nothing -> nothing {
    mkdir ($file | path dirname)
    $lines | str join "\n" | $"($in)\n" | save --force $file
}

def tree-good [dir: path]: nothing -> nothing {
    write-lines ($dir | path join configs base packages.txt) [
        "# base module: a header comment"
        ""
        "base                              # Arch base group"
        "base-devel"
        "libc++                            # a name with +"
        "trailing-space   \t"
        "shared                            # also in desktop"
    ]
    # the hardware-only half, beside the module's packages.txt
    write-lines ($dir | path join configs base packages.native.txt) [native-only shared]
    # a config dir inside a module, not a module of its own
    write-lines ($dir | path join configs base btop packages.txt) [nested-not-a-module]
    write-lines ($dir | path join configs base btop packages.native.txt) [nested-native]
    write-lines ($dir | path join configs desktop packages.txt) [shared desktop-only "\t# an indented comment"]
    write-lines ($dir | path join configs desktop flatpacks.txt) [org.example.FlatpakOnly]
    write-lines ($dir | path join configs programming packages.txt) [rust extra-dup]
    write-lines ($dir | path join configs programming nixpkgs.txt) [nixpkg-only]
    write-lines ($dir | path join configs docs README.md) ["a module without packages"]
    write-lines ($dir | path join platforms pc.sh) [HOSTNAME=pc FORM_FACTOR=desktop "EXTRA_PACKAGES=(pc-extra extra-dup)" "PKG_GROUPS=(base desktop)"]
    write-lines ($dir | path join platforms notebook.sh) [HOSTNAME=notebook "EXTRA_PACKAGES=(notebook-extra)"]
    write-lines ($dir | path join platforms wsl.sh) [HOSTNAME=wsl "PKG_GROUPS=(base programming)"]
    write-lines ($dir | path join mirror pkgbuilds local-recipe PKGBUILD) [pkgname=local-recipe]
}

# a copy of the good tree, changed by the closure, which gets the copy's root
def variant [good: path, name: string, change: closure]: nothing -> path {
    let dir = $env.PWD | path join $name
    rm --recursive --force $dir
    ^cp -r $good $dir
    do $change $dir
    $dir
}

# refused, nothing printed, the reason named
def expect-fail [tree: path, reason: string, name: string]: nothing -> nothing {
    let got = list-run $tree
    if $got.exit_code == 0 { fail $"($name): accepted" }
    if $got.stdout != "" { fail $"($name): printed a partial list: ($got.stdout | lines | first 3)" }
    if not ($got.stderr | str contains $reason) { fail $"($name): message '($got.stderr)' lacks '($reason)'" }
    pass $name
}

# a desc section, nothing for no values
def desc-section [title: string, values: list<string>]: nothing -> string {
    if ($values | is-empty) { "" } else { $"%($title)%\n($values | str join "\n")\n\n" }
}

# a sync db as repo-add writes it; an entry is {name, provides?, groups?, depends?, open?}, open leaving out the blank
# line after its last section
def db-make [db: path, entries: list<record>]: nothing -> nothing {
    let dir = mktemp --directory
    for entry in $entries {
        let desc_dir = $dir | path join $"($entry.name)-1-1"
        mkdir $desc_dir
        let desc = [
            $"%FILENAME%\n($entry.name)-1-1-x86_64.pkg.tar.zst\n\n%NAME%\n($entry.name)\n\n%VERSION%\n1-1\n\n"
            (desc-section PROVIDES ($entry.provides? | default []))
            (desc-section GROUPS ($entry.groups? | default []))
            (desc-section DEPENDS ($entry.depends? | default []))
        ] | str join
        let desc = if ($entry.open? | default false) { $desc | str replace --regex '\n\n$' "\n" } else { $desc }
        $desc | save --force ($desc_dir | path join desc)
    }
    ^bsdtar -czf $db -C $dir .
    rm --recursive --force $dir
}

def names [...names: string]: nothing -> list<record> {
    $names | each {|name| {name: $name} }
}

def all-but [...left: string]: nothing -> list<record> {
    names ...($ALL | where $it not-in $left)
}

def layout-cases [good: path]: nothing -> nothing {
    let got = list-run $good
    if $got.exit_code != 0 { fail $"the good tree: ($got.stderr)" }
    if ($got.stdout | lines) != $ALL { fail $"the list of the good tree: ($got.stdout | lines)" }
    pass "every module's packages.txt and packages.native.txt and every platform's EXTRA_PACKAGES, sorted and unique"

    let generated = variant $good generated {|d|
        write-lines ($d | path join mirror packages.txt) ["# dot gen" base generated-only "shared   # twice" shared]
    }
    let got = list-run $generated
    if ($got.stdout | lines) != [base extra-dup generated-only notebook-extra pc-extra shared] {
        fail $"the generated list: ($got.stdout | lines) ($got.stderr)"
    }
    pass "mirror/packages.txt stands in for the modules, the platforms still join"

    expect-fail (variant $good upper {|d| "Upper-Case\n" | save --append ($d | path join configs desktop packages.txt) }) "configs/desktop/packages.txt: 'Upper-Case' is not a package name" "an upper case name is refused"
    expect-fail (variant $good two {|d| "two names\n" | save --append ($d | path join configs base packages.txt) }) "'two names' is not a package name" "two names on one line are refused"
    expect-fail (variant $good indented {|d| "  indented\n" | save --append ($d | path join configs base packages.txt) }) "'  indented' is not a package name" "a name install.sh would pass with leading blanks is refused"
    expect-fail (variant $good extra {|d| "EXTRA_PACKAGES=(-leading)\n" | save --append ($d | path join platforms notebook.sh) }) "platforms/notebook.sh: '-leading' is not a package name" "a bad EXTRA_PACKAGES entry is refused"
    let dangling = variant $good dangling {|d| let f = $d | path join configs desktop packages.txt; rm $f; ^ln -s missing.txt $f }
    expect-fail $dangling $"cannot read ($dangling)/configs/desktop/packages.txt" "an unreadable manifest is refused"
    let dangling_native = variant $good dangling-native {|d| let f = $d | path join configs base packages.native.txt; rm $f; ^ln -s missing.txt $f }
    expect-fail $dangling_native $"cannot read ($dangling_native)/configs/base/packages.native.txt" "an unreadable native manifest is refused"
    let syntax = variant $good syntax {|d| "EXTRA_PACKAGES=(\n" | save --append ($d | path join platforms pc.sh) }
    expect-fail $syntax $"cannot source ($syntax)/platforms/pc.sh" "a platform file that does not source is refused"
    let empty = variant $good empty {|d|
        for file in (glob ($d | path join configs * "packages*.txt")) { "# nothing yet\n" | save --force $file }
        rm ($d | path join platforms pc.sh) ($d | path join platforms notebook.sh)
    }
    expect-fail $empty $"no package names in ($empty)" "an empty set is refused"

    # the layout before the module move: the arrays lived in install.sh, no module has a packages.txt
    let old = $env.PWD | path join old
    write-lines ($old | path join install.sh) ["PACKAGES=(" "    base" ")"]
    write-lines ($old | path join configs pacman archrepo.asc) [key]
    write-lines ($old | path join platforms pc.sh) (open --raw ($good | path join platforms pc.sh) | lines)
    expect-fail $old $"no configs/<module>/packages.txt in ($old)" "an old-layout checkout is refused, not read as extras alone"
}

def db-cases [good: path]: nothing -> nothing {
    # <case> <db entries> <listed names the db must miss>
    let cases = [
        [name entries want];
        ["an empty db (a first run) lacks every listed name" [] $ALL]
        ["a listed name the db has is not missing, an unlisted one is not reported" (all-but rust | append (names zzz-unlisted)) [rust]]
        ["a provides counts, its version constraint dropped" (all-but rust | append {name: rustup, provides: [rust=1.80.0 cargo]}) []]
        ["a group counts" (all-but base-devel | append {name: gcc, groups: [base-devel]}) []]
        ["a depends does not count" (all-but rust | append {name: cargo-tools, depends: [rust]}) [rust]]
        ["a near name does not count" (all-but rust | append (names rust-analyzer) | append {name: rusty, provides: [rust-src]}) [rust]]
        ["a desc without its closing blank line still counts" (all-but rust | append {name: rustup, provides: [rust], open: true}) []]
        ["a section of a desc without its closing blank line ends at the next" (all-but rust | append {name: cargo-tools, groups: [tools], depends: [rust], open: true}) [rust]]
    ]
    for case in $cases {
        db-make provided.db.tar.gz $case.entries
        let got = list-run $good provided.db.tar.gz
        if $got.exit_code != 0 { fail $"($case.name): refused: ($got.stderr)" }
        if ($got.stdout | lines) != $case.want { fail $"($case.name): missing ($got.stdout | lines), want ($case.want)" }
        pass $case.name
    }

    "garbage\n" | save --force garbage.db.tar.gz
    let got = list-run $good garbage.db.tar.gz
    if $got.exit_code == 0 { fail "an unreadable db: accepted" }
    if $got.stdout != "" { fail $"an unreadable db: printed a partial list: ($got.stdout)" }
    if not ($got.stderr | str contains "cannot read garbage.db.tar.gz") { fail $"an unreadable db: message '($got.stderr)'" }
    pass "an unreadable db fails the list and prints nothing"
}

def gate-cases [good: path]: nothing -> nothing {
    let everything = names ...$ALL
    # <case> <served db entries, null for none> <proposed db entries> <names that hold the night back> <missing once served>
    let cases = [
        [name served proposed lost missing];
        ["a first run publishes what it has, the rest shows as missing" null (all-but rust) [] [rust]]
        ["a never-built name does not hold the night back and stays missing" (all-but rust) (all-but rust) [] [rust]]
        ["a served name the night would lose holds it back, the served snapshot stays whole" $everything (all-but rust) [rust] []]
        ["a served name kept through another package's provides is not lost" $everything (all-but rust | append {name: rustup, provides: [rust]}) [] []]
        ["only lost names hold back, the never-built one stays reported" (all-but pc-extra) (all-but pc-extra shared) [shared] [pc-extra]]
        ["a night that builds a missing name clears it" (all-but rust) $everything [] []]
    ]
    for case in $cases {
        let work = $env.PWD | path join work
        let repo_dir = $env.PWD | path join served
        rm --recursive --force $work $repo_dir
        mkdir ($work | path join db) $repo_dir
        let c = context-default | merge {list_script: (list-script), dotfiles: $good, work: $work, repo_dir: $repo_dir}
        let served_db = $repo_dir | path join $"($REPO).db.tar.gz"
        let proposed_db = $work | path join db $"($REPO).db.tar.gz"
        if $case.served != null { db-make $served_db $case.served }
        db-make $proposed_db $case.proposed
        # publish-main's order: the served gaps first, the gate after the db is assembled
        let p = publish-empty | upsert snapshot_missing (listed-missing $c $served_db)
        let p = completeness-check $c $p (listed-missing $c $proposed_db)
        let want_held = if ($case.lost | is-empty) { "" } else { $"listed names the served snapshot has and this one lacks: ($case.lost | str join ' ')" }
        if $p.held_back != $want_held { fail $"($case.name): held back '($p.held_back)', want '($want_held)'" }
        let missing = if $p.held_back == "" { $p.proposed_missing } else { $p.snapshot_missing }
        if $missing != $case.missing { fail $"($case.name): missing ($missing), want ($case.missing)" }
        pass $case.name
    }
}

def main []: nothing -> nothing {
    let good = $env.PWD | path join good
    tree-good $good
    layout-cases $good
    db-cases $good
    gate-cases $good
}
