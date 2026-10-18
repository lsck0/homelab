#!/usr/bin/env -S nu --no-config-file
# print every package name the lsck0 snapshot serves, read from an arch-dotfiles checkout
#
# usage: archrepo-list.nu <dotfiles dir> [<sync db>]
#
# The snapshot serves every machine, so the list is the union over all of them: mirror/packages.txt where the checkout
# has it (`dot gen` writes the module union there), else the packages.txt of every configs/<module>/ and the
# packages.native.txt beside it; plus the EXTRA_PACKAGES of every platforms/*.sh. A manifest is read like install.sh
# read_manifest: one name per line, `#` comments, trailing whitespace and blank lines dropped. Prints the names sorted
# and unique. With a sync db (repo-add's <repo>.db.tar.gz) it prints only the listed names the db provides neither as
# a name, a provides nor a group, the three ways pacman -S resolves a target.
#
# An unreadable manifest, a platform file that does not source, an entry that is not a package name, an empty list
# and an unreadable db fail the whole run: archrepo-build.nu prunes what the list misses from the served db.

const MIRROR_MANIFEST = "mirror/packages.txt"
const MODULES = "configs"
const MANIFEST = "packages.txt"
const NATIVE_MANIFEST = "packages.native.txt"
const PLATFORMS = "platforms"
# makepkg's pkgname rule: alphanumerics and @._+-, not starting with a hyphen or a dot
const NAME_PATTERN = '^[a-z0-9@_+][a-z0-9@._+-]*$'
# a desc section of these, up to the blank line that ends it; no package name, provides or group starts with %
const DB_SECTION_PATTERN = '(?m)^%(?:NAME|PROVIDES|GROUPS)%\n(?P<values>(?:[^%\n][^\n]*(?:\n|$))*)'
# sourced like install.sh did, in a clean shell of its own; an unset EXTRA_PACKAGES prints one empty line
const PLATFORM_EXTRA = 'source "$1" >/dev/null && printf "%s\n" "${EXTRA_PACKAGES[@]}"'

def die [message: string]: nothing -> nothing {
    print -e $"archrepo-list: ($message)"
    exit 1
}

def names-check [source: path, names: list<string>]: nothing -> list<string> {
    let bad = $names | where $it !~ $NAME_PATTERN
    if ($bad | is-not-empty) { die $"($source): '($bad | first)' is not a package name" }
    $names
}

def manifest-read [file: path]: nothing -> list<string> {
    let entries = try { open --raw $file | lines } catch { die $"cannot read ($file)" }
    names-check $file ($entries | each { str replace --regex '#.*' '' | str trim --right } | where $it != "")
}

def manifests [dotfiles: path]: nothing -> list<path> {
    let mirror = $dotfiles | path join $MIRROR_MANIFEST
    if ($mirror | path exists) { return [$mirror] }
    let modules = $dotfiles | path join $MODULES
    let dirs = if ($modules | path type) == dir { ls $modules | get name | sort } else { [] }
    # a dangling link counts, so it fails as unreadable instead of dropping its names
    let beside = {|name| $dirs | each { path join $name } | where { $in | path type | is-not-empty } }
    let manifests = do $beside $MANIFEST
    if ($manifests | is-empty) { die $"no ($MODULES)/<module>/($MANIFEST) in ($dotfiles)" }
    $manifests | append (do $beside $NATIVE_MANIFEST)
}

def platform-extra [bash: path, file: path]: nothing -> list<string> {
    let got = do { ^env -i $bash -c $PLATFORM_EXTRA platform $file } | complete
    if $got.exit_code != 0 { die $"cannot source ($file) for its EXTRA_PACKAGES" }
    names-check $file ($got.stdout | lines | where $it != "")
}

def listed-names [dotfiles: path]: nothing -> list<string> {
    let platform_dir = $dotfiles | path join $PLATFORMS
    let platforms = if ($platform_dir | path type) == dir {
        ls $platform_dir | get name | where { str ends-with ".sh" } | sort
    } else { [] }
    let extra = if ($platforms | is-empty) { [] } else {
        let bash = which bash | get 0.path
        $platforms | each {|file| platform-extra $bash $file } | flatten
    }
    let names = manifests $dotfiles | each {|file| manifest-read $file } | flatten | append $extra
    if ($names | is-empty) { die $"no package names in ($dotfiles)" }
    $names | sort | uniq
}

# every name, provides (version dropped) and group of the db's desc entries
def db-provided [db: path]: nothing -> list<string> {
    let got = do { ^bsdtar -xOf $db } | complete
    if $got.exit_code != 0 { die $"cannot read ($db)" }
    $got.stdout | parse --regex $DB_SECTION_PATTERN | get values | each { lines } | flatten
    | each { str replace --regex '[<>=].*' '' }
}

def main [dotfiles: path, db?: path]: nothing -> nothing {
    let listed = listed-names $dotfiles
    let printed = if $db == null { $listed } else {
        let provided = db-provided $db | uniq | each {|name| {name: $name, value: true} }
        let provided = if ($provided | is-empty) { {} } else { $provided | transpose -r -d }
        $listed | where {|name| ($provided | get -o $name) == null }
    }
    if ($printed | is-not-empty) { print ($printed | str join "\n") }
}
