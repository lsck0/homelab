# lib/mc-mod.nu's verdict on a jar: the version ranges neoforge (maven) and fabric declare, what a jar declares, what
# a server runs according to its modpack.env, and the refusal add prints. The jars are built here with the metadata
# of the two jars atm runs (LitematicaTool 2.0.0's ranges, Mahou Tsukai's none).
#
# usage: nu mc_mod_test.nu, beside ../lib/mc-mod.nu

use ../lib/mc-mod.nu *

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def pass [message: string]: nothing -> nothing {
    print $"PASS: ($message)"
}

def expect [label: string, actual: any, expected: any]: nothing -> nothing {
    if $actual != $expected { fail $"($label): got ($actual | to nuon), expected ($expected | to nuon)" }
}

# a jar holding one metadata file at its path inside the jar
def jar-build [dir: path, name: string, inside: string, text: string]: nothing -> path {
    let stage = $dir | path join $"($name).stage"
    mkdir ($stage | path join ($inside | path dirname))
    $text | save --force ($stage | path join $inside)
    let jar = $dir | path join $"($name).jar"
    cd $stage
    ^zip -q -r $jar .
    $jar
}

def neoforge-toml [id: string, minecraft: string]: nothing -> string {
    $'modLoader = "javafml"
loaderVersion = "[2,)"
license = "CC0-1.0"

[[mods]]
modId = "($id)"
version = "2.0.0"

[[dependencies.($id)]]
modId = "neoforge"
type = "required"
versionRange = "[21.0,)"

[[dependencies.($id)]]
modId = "minecraft"
type = "required"
versionRange = "($minecraft)"

[[dependencies.($id)]]
modId = "sodium"
type = "incompatible"
versionRange = "[0.1,)"
'
}

def test-versions []: nothing -> nothing {
    expect "1.21 is 1.21.0" (version-compare "1.21" "1.21.0") 0
    expect "a pre-release before its release" (version-compare "21.1.0-beta" "21.1.0") (-1)
    expect "numeric, not textual" (version-compare "1.21.10" "1.21.9") 1
    pass "versions compare by their numbers, then their qualifier"
}

def test-maven []: nothing -> nothing {
    let cases = [
        [range version admits];
        ["[1.21,1.21.1)" "1.21.1" false]
        ["[1.21,1.21.2)" "1.21.1" true]
        ["[1.21,1.21.2)" "1.21" true]
        ["(1.21,1.21.2)" "1.21" false]
        ["[1.21,1.21.1]" "1.21.1" true]
        ["[1.21.1]" "1.21.1" true]
        ["[1.21.1]" "1.21" false]
        ["[21.0,)" "21.1.249" true]
        ["(,1.21)" "1.21" false]
        ["[21.1.0-beta,)" "21.1.0" true]
        ["[1.20,1.20.1],[1.21,1.21.2)" "1.21.1" true]
        ["[1.20,1.20.1],[1.21,1.21.1)" "1.21.1" false]
        ["1.21.1" "1.20" true]
        ["" "1.21.1" true]
    ]
    for case in $cases {
        expect $"($case.range) admits ($case.version)" (maven-range-contains $case.range $case.version) $case.admits
    }
    pass $"maven ranges: ($cases | length) cases"
}

def test-fabric []: nothing -> nothing {
    let cases = [
        [range version admits];
        [["~1.21.1"] "1.21.4" true]
        [["~1.21.1"] "1.22" false]
        [["~1.21.1"] "1.21" false]
        [[">=1.21 <1.21.2"] "1.21.1" true]
        [[">=1.21 <1.21.2"] "1.21.2" false]
        [["1.21.x"] "1.21.5" true]
        [["1.21.x"] "1.22" false]
        [["1.21.1"] "1.21" false]
        [["^1.21"] "1.99" true]
        [["^1.21"] "2.0" false]
        [["*"] "1.21.1" true]
        [["1.20.1" "1.21.1"] "1.21.1" true]
        [["1.20.1" "1.21"] "1.21.1" false]
    ]
    for case in $cases {
        expect $"($case.range | str join ' or ') admits ($case.version)" (fabric-range-contains $case.range $case.version) $case.admits
    }
    pass $"fabric predicates: ($cases | length) cases"
}

def test-jars [dir: path]: nothing -> nothing {
    let fits = jar-read (jar-build $dir fits "META-INF/neoforge.mods.toml" (neoforge-toml litematicatool "[1.21,1.21.2)"))
    expect "neoforge jar" $fits {
        loader: neoforge, ids: [litematicatool], version: "2.0.0"
        ranges: [{id: neoforge, range: ["[21.0,)"]} {id: minecraft, range: ["[1.21,1.21.2)"]}]
    }
    let bare = jar-read (jar-build $dir bare "META-INF/neoforge.mods.toml" '[[mods]]
modId="mahoutsukai"
version="1.21.1-v1.36.28"
')
    expect "a neoforge jar with no dependencies" $bare.ranges []
    let fabric = jar-read (jar-build $dir fabric "fabric.mod.json" ({
        id: lithium, version: "0.15.0", depends: {fabricloader: ">=0.16", minecraft: ["1.21", "1.21.1"]}
    } | to json))
    expect "fabric jar" $fabric {loader: fabric, ids: [lithium], version: "0.15.0", ranges: [{id: minecraft, range: ["1.21" "1.21.1"]}]}
    let none = jar-build $dir none "META-INF/MANIFEST.MF" "Manifest-Version: 1.0\n"
    let refused = do { ^$nu.current-exe --no-config-file -c $"use ($env.FILE_PWD)/../lib/mc-mod.nu *; jar-read ($none)" } | complete
    if $refused.exit_code == 0 or $refused.stderr !~ "no neoforge or fabric mod" { fail $"a plain jar was read: ($refused)" }
    pass "jars: neoforge and fabric metadata read, ranges of other mods and incompatibilities left out, a plain jar refused"
}

def test-servers [dir: path]: nothing -> nothing {
    let atm = $dir | path join atm.env
    "TYPE=NEOFORGE\nVERSION=1.21.1\nNEOFORGE_VERSION=21.1.249\nMODS=/modpacks/atm-extra\n" | save --force $atm
    expect "atm" (server-read atm null $atm) {name: atm, minecraft: "1.21.1", loader: neoforge, loader_version: "21.1.249"}
    let pack = $dir | path join pack.env
    "TYPE=MODRINTH\nVERSION=LATEST\nMODRINTH_MODPACK=/modpacks/x.mrpack\n" | save --force $pack
    expect "a pack pinning no version" (server-read cobblemon "1.21.1" $pack) {name: cobblemon, minecraft: "1.21.1", loader: null, loader_version: null}
    expect "a server never started" (server-read vanilla null ($dir | path join missing.env)) {name: vanilla, minecraft: null, loader: null, loader_version: null}
    pass "servers: version and loader from modpack.env, the declared version for a pack that pins none"
}

def test-refusals [dir: path]: nothing -> nothing {
    let atm = {name: atm, minecraft: "1.21.1", loader: neoforge, loader_version: "21.1.249"}
    let fits = jar-read ($dir | path join fits.jar)
    expect "a mod for 1.21 to 1.21.1" (mod-refusal $fits $atm) null
    expect "a mod declaring nothing" (mod-refusal (jar-read ($dir | path join bare.jar)) $atm) null
    let old = jar-read (jar-build $dir old "META-INF/neoforge.mods.toml" (neoforge-toml old "[1.21,1.21.1)"))
    expect "a mod for 1.21.0 only" (mod-refusal $old $atm) "it needs minecraft [1.21,1.21.1), atm runs 1.21.1"
    expect "a newer neoforge" (mod-refusal $fits ($atm | update loader_version "20.4.1")) "it needs neoforge [21.0,), atm runs 20.4.1"
    let fabric = jar-read ($dir | path join fabric.jar)
    expect "another loader" (mod-refusal $fabric $atm) "it is a fabric mod and atm runs neoforge"
    let pack = {name: cobblemon, minecraft: "1.21.1", loader: null, loader_version: null}
    expect "a pack's own loader: only minecraft checked" (mod-refusal $fabric $pack) null
    expect "a fabric mod for another version" (mod-refusal $fabric ($pack | update minecraft "1.21.4")) "it needs minecraft 1.21 or 1.21.1, cobblemon runs 1.21.4"
    expect "vanilla" (mod-refusal $fits {name: vanilla, minecraft: "1.21.1", loader: vanilla, loader_version: null}) "vanilla runs vanilla, which loads no mods"
    expect "no version" (mod-refusal $fits ($pack | update minecraft null)) "the minecraft version of cobblemon is unknown: its pack pins none and none is declared"
    pass "refusals: each names what the mod needs and what the server runs"
}

def main []: nothing -> nothing {
    let dir = mktemp --directory
    test-versions
    test-maven
    test-fabric
    test-jars $dir
    test-servers $dir
    test-refusals $dir
    rm --recursive --force $dir
}
