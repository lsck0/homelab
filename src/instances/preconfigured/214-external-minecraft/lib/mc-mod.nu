#!/usr/bin/env -S nu --no-config-file
# the extra mods of a server: jars beside its pack, in <extraMods>/<server>, copied into its mods at every start
#
# usage: mc-mod list [server] | mc-mod add <server> <jar> | mc-mod remove <server> <file or mod id>
#
# add reads the jar's own metadata and refuses a mod the server cannot load: another loader, or a minecraft or
# neoforge range that leaves out the server's version (the pack's modpack.env, or the declared version for a pack
# that names none). A mod the start refuses ends the start, so a wrong jar would keep every player out. The settings
# (servers, dirs, owner) are main.nix's, in the file $MC_MOD_SETTINGS names.

const NEOFORGE_METADATA = "META-INF/neoforge.mods.toml"
const FABRIC_METADATA = "fabric.mod.json"
const JAR_MODE = "0640"
const DIR_MODE = "0750"
# the dependency ids the ranges are checked for: the game and the loader the server runs
const MINECRAFT = "minecraft"
const NEOFORGE = "neoforge"
const FABRIC = "fabric"
# the image's TYPE -> the loader it runs; a pack type (MODRINTH, AUTO_CURSEFORGE) brings its own, unknown here
const LOADERS = {NEOFORGE: "neoforge", FABRIC: "fabric", VANILLA: "vanilla"}
# what a pack that pins no version asks for
const VERSION_LATEST = "LATEST"
# dependency types neoforge never requires a range of
const NEOFORGE_UNCHECKED = [incompatible discouraged]

def die [message: string]: nothing -> nothing {
    print -e $"mc-mod: ($message)"
    exit 1
}

def settings []: nothing -> record {
    open --raw $env.MC_MOD_SETTINGS | from json
}

# 1.21.1 -> [1 21 1] and no qualifier; 21.1.0-beta -> [21 1 0] and "beta"; a part without digits counts as 0
def version-parse [version: string]: nothing -> record {
    let parts = $version | split row --number 2 "-"
    let numbers = $parts.0 | split row "." | each {|part|
        $part | parse --regex '^(?<digits>\d+)' | get -o 0.digits | default "0" | into int
    }
    {numbers: $numbers, qualifier: ($parts | get -o 1 | default "")}
}

# -1, 0 or 1; missing parts are 0 (1.21 == 1.21.0) and a release sorts after its pre-releases (21.1.0-beta < 21.1.0)
export def version-compare [a: string, b: string]: nothing -> int {
    let a = version-parse $a
    let b = version-parse $b
    let width = [($a.numbers | length) ($b.numbers | length)] | math max
    let differ = 0..<$width | each {|i| [($a.numbers | get -o $i | default 0) ($b.numbers | get -o $i | default 0)] }
        | where { $in.0 != $in.1 } | get -o 0
    if $differ != null { return (if $differ.0 < $differ.1 { -1 } else { 1 }) }
    if $a.qualifier == $b.qualifier { return 0 }
    if $a.qualifier == "" { return 1 }
    if $b.qualifier == "" { return (-1) }
    if $a.qualifier < $b.qualifier { -1 } else { 1 }
}

# maven's range as neoforge.mods.toml writes it: [1.21,1.21.2), [1.21.1], [21.0,), unions of them; a bare version is
# maven's recommendation, which admits every version
export def maven-range-contains [range: string, version: string]: nothing -> bool {
    let bounds = $range | str replace --all " " ""
        | parse --regex '(?<open>[\[(])(?<low>[^,\])]*)(?<comma>,?)(?<high>[^\])]*)(?<close>[\])])'
    if ($bounds | is-empty) { return true }
    $bounds | any {|bound|
        if $bound.comma == "" {
            (version-compare $version $bound.low) == 0
        } else {
            let above = $bound.low == "" or (version-compare $version $bound.low) >= (if $bound.open == "[" { 0 } else { 1 })
            let below = $bound.high == "" or (version-compare $version $bound.high) <= (if $bound.close == "]" { 0 } else { -1 })
            $above and $below
        }
    }
}

# the version past every one that shares its first <depth> parts: 1.21.1 at depth 2 -> 1.22
def version-next [version: string, depth: int]: nothing -> string {
    let numbers = (version-parse $version).numbers | append [0 0] | first $depth
    $numbers | update ($depth - 1) { $in + 1 } | str join "."
}

# one of fabric's predicates: space-separated terms that all hold (>=1.21 <1.21.2, ~1.21.1, ^1.21, 1.21.x, 1.21.1, *)
def fabric-predicate-contains [predicate: string, version: string]: nothing -> bool {
    $predicate | split row " " | where $it != "" | all {|term|
        let found = $term | parse --regex '^(?<op>>=|<=|>|<|=|~|\^)?(?<target>.+)$' | first
        let target = $found.target
        let order = version-compare $version $target
        match $found.op {
            ">=" => ($order >= 0)
            ">" => ($order > 0)
            "<=" => ($order <= 0)
            "<" => ($order < 0)
            "~" => ($order >= 0 and (version-compare $version (version-next $target 2)) < 0)
            "^" => ($order >= 0 and (version-compare $version (version-next $target 1)) < 0)
            _ => {
                if $target == "*" { return true }
                let wildcard = $target | parse --regex '^(?<prefix>.+)\.[xX*]$' | get -o 0.prefix
                if $wildcard == null {
                    $order == 0
                } else {
                    let depth = $wildcard | split row "." | length
                    (version-parse $version).numbers | append [0 0 0] | first $depth
                        | zip ((version-parse $wildcard).numbers) | all { $in.0 == $in.1 }
                }
            }
        }
    }
}

# fabric.mod.json's depends value: one predicate, or a list of which any one admits the version
export def fabric-range-contains [range: list<string>, version: string]: nothing -> bool {
    $range | any { fabric-predicate-contains $in $version }
}

# the loader, mod ids, version and the minecraft and loader ranges a jar declares
export def jar-read [jar: path]: nothing -> record {
    let neoforge = do { ^unzip -p $jar $NEOFORGE_METADATA } | complete
    if $neoforge.exit_code == 0 {
        let toml = $neoforge.stdout | from toml
        let mods = $toml.mods? | default []
        let ranges = $toml.dependencies? | default {} | values | flatten
            | where { ($in.type? | default "required") not-in $NEOFORGE_UNCHECKED }
            | where { $in.modId? in [$MINECRAFT $NEOFORGE] }
            | each {|dependency| {id: $dependency.modId, range: [($dependency.versionRange? | default "")]} }
        return {loader: $NEOFORGE, ids: $mods.modId, version: ($mods | get -o 0.version | default "?"), ranges: $ranges}
    }
    let fabric = do { ^unzip -p $jar $FABRIC_METADATA } | complete
    if $fabric.exit_code != 0 {
        die $"($jar) holds neither ($NEOFORGE_METADATA) nor ($FABRIC_METADATA): no neoforge or fabric mod"
    }
    let json = $fabric.stdout | from json
    let ranges = $json.depends? | default {} | transpose id range | where id == $MINECRAFT
        | each {|dependency| {id: $dependency.id, range: ([$dependency.range] | flatten)} }
    {loader: $FABRIC, ids: [$json.id], version: ($json.version? | default "?"), ranges: $ranges}
}

# what a server runs: its minecraft version, its loader and the loader's version, each null when its pack decides
export def server-read [name: string, declared: any, modpack_env: path]: nothing -> record {
    let pack = if ($modpack_env | path exists) {
        open --raw $modpack_env | lines | parse --regex '^(?<key>[A-Z_]+)=(?<value>.*)$'
            | reduce --fold {} {|line, pack| $pack | upsert $line.key $line.value }
    } else { {} }
    let pinned = $pack.VERSION? | default $VERSION_LATEST
    let loader = $LOADERS | get -o ($pack.TYPE? | default "")
    {
        name: $name
        minecraft: (if $pinned != $VERSION_LATEST { $pinned } else { $declared })
        loader: $loader
        loader_version: (if $loader == $NEOFORGE { $pack.NEOFORGE_VERSION? } else { null })
    }
}

# why the server cannot load the mod, or null
export def mod-refusal [mod: record, server: record]: nothing -> any {
    if $server.loader == "vanilla" { return $"($server.name) runs vanilla, which loads no mods" }
    if $server.loader != null and $server.loader != $mod.loader {
        return $"it is a ($mod.loader) mod and ($server.name) runs ($server.loader)"
    }
    if $server.minecraft == null {
        return $"the minecraft version of ($server.name) is unknown: its pack pins none and none is declared"
    }
    let runs = {minecraft: $server.minecraft, neoforge: $server.loader_version}
    let misses = $mod.ranges | where {|dependency|
        let version = $runs | get $dependency.id
        if $version == null {
            false
        } else if $mod.loader == $NEOFORGE {
            not (maven-range-contains $dependency.range.0 $version)
        } else {
            not (fabric-range-contains $dependency.range $version)
        }
    }
    if ($misses | is-empty) { return null }
    $misses | each {|miss|
        $"it needs ($miss.id) ($miss.range | str join ' or '), ($server.name) runs ($runs | get $miss.id)"
    } | str join "; "
}

def server-find [name: string]: nothing -> record {
    let all = settings
    let server = $all.servers | where name == $name | get -o 0
    if $server == null { die $"no server ($name); the servers are ($all.servers.name | str join ', ')" }
    $server | insert dir ($all.extraMods | path join $name)
}

def jars-of [dir: path]: nothing -> list<string> {
    if ($dir | path exists) { glob ($dir | path join "*.jar") | sort } else { [] }
}

def restart-hint [server: record]: nothing -> nothing {
    print $"($server.name) loads it at its next start; now, while mc-state shows nobody on: systemctl restart ($server.unit)"
}

def main []: nothing -> nothing {
    print "usage: mc-mod list [server] | mc-mod add <server> <jar> | mc-mod remove <server> <file or mod id>"
}

# every extra mod of every server, or of one, a line each: a table needs a terminal, and ssh gives none
def "main list" [server?: string]: nothing -> nothing {
    let names = if $server == null { (settings).servers.name } else { [(server-find $server).name] }
    for name in $names {
        let jars = jars-of (server-find $name).dir
        if ($jars | is-empty) { print $"($name): none" }
        for jar in $jars {
            let mod = jar-read $jar
            print $"($name): ($jar | path basename) \(($mod.ids | str join ' ') ($mod.version), ($mod.loader)\)"
        }
    }
}

# install a jar the server can load, in place of any jar that holds the same mod
def "main add" [server: string, jar: path]: nothing -> nothing {
    let all = settings
    let target = server-find $server
    let mod = jar-read $jar
    let runs = server-read $server $target.version ($all.data | path join $server modpack.env)
    let refusal = mod-refusal $mod $runs
    if $refusal != null { die $"refusing ($jar | path basename) for ($server): ($refusal)" }
    let file = $jar | path basename
    let replaced = jars-of $target.dir | where {|other|
        ($other | path basename) != $file and ((jar-read $other).ids | any { $in in $mod.ids })
    }
    ^install -d -m $DIR_MODE -o $all.owner -g $all.group $all.extraMods $target.dir
    ^install -m $JAR_MODE -o $all.owner -g $all.group $jar ($target.dir | path join $file)
    for other in $replaced {
        rm $other
        print $"removed ($other | path basename), the same mod"
    }
    print $"added ($file) \(($mod.ids | str join ' ') ($mod.version)\) to ($server)"
    restart-hint $target
}

# remove the jar named by its file or by a mod id it holds
def "main remove" [server: string, name: string]: nothing -> nothing {
    let target = server-find $server
    let jars = jars-of $target.dir
    let matches = $jars | where {|jar| ($jar | path basename) == $name or $name in (jar-read $jar).ids }
    if ($matches | is-empty) {
        let present = $jars | path basename | str join ", "
        die $"($server) has no extra mod ($name); it has: (if $present == '' { 'none' } else { $present })"
    }
    for jar in $matches {
        rm $jar
        print $"removed ($jar | path basename) from ($server)"
    }
    restart-hint $target
}
