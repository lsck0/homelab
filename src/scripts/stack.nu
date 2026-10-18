#!/usr/bin/env -S nu --no-config-file
# toggle a boot phase's guests (vm.power in their instance.nix), then ./sync.nu
#
# Every guest's phase, power and declaring file come from the collector (`nix eval .#lab.instances`); a write edits only
# that file: its `power` line, or a new one after its bootPhase line where the schema's default held. The swarm's
# workers share one file (src/instances/core/swarm.nix) and turn together; an app's own guest follows the app's
# `enable`. Whether a guest idles is its instance.nix `idle`, not a phase's state.

const SRC = path self | path dirname | path dirname
use lib/tools.nu [die tools-require]

# the toggleable groups are boot phases; the rest of the lab depends on nas, network and dev
const PHASES = [apps media public]
const STATES = [on off]
const PROJECTION = "is: builtins.mapAttrs (_: i: { inherit (i) source; inherit (i.config.vm) bootPhase power; }) is"
const APP_SOURCE_SUFFIX = "/app.nix"
const INSTANCE_SOURCE_SUFFIX = "/instance.nix"
const NAME_WIDTH = 34

def usage []: nothing -> nothing {
    die --misuse $"usage: stack.nu status | {($PHASES | str join '|')} {($STATES | str join '|')} [--apply]"
}

# every guest stack.nu turns: {source (relative to src), phase, power}
def guests-load []: nothing -> table {
    let evaluated = do { ^nix eval --json --no-warn-dirty $"($SRC)#lab.instances" --apply $PROJECTION } | complete
    if $evaluated.exit_code != 0 { die $"the lab does not evaluate \(nix eval .#lab.instances\):\n($evaluated.stderr)" }
    $evaluated.stdout | from json | values
        | where { not ($in.source | str ends-with $APP_SOURCE_SUFFIX) }
        | each { {source: $in.source, phase: $in.bootPhase, power: $in.power} }
        | sort-by source
}

def guest-name [source: string]: nothing -> string {
    if ($source | str ends-with $INSTANCE_SOURCE_SUFFIX) { $source | path dirname | path basename } else { $source }
}

# `[vm.]<field> = "<value>";` on a line of its own: {indent, prefix, line}, null when the file does not set it
def field-find [text: string, field: string]: nothing -> any {
    $text | parse --regex ('(?m)^(?<indent>[ \t]*)(?<prefix>(?:vm\.)?)' + $field + '\s*=\s*"[^"]*"\s*;(?<rest>.*)$') | get --optional 0
}

# the text with `power` set to <want>
def power-set [text: string, want: string, file: path]: nothing -> string {
    let line_regex = '(?m)^([ \t]*)((?:vm\.)?)power\s*=\s*"[^"]*"\s*;'
    if (field-find $text power) != null {
        return ($text | str replace --regex $line_regex $"${1}${2}power = \"($want)\";")
    }
    let phase = field-find $text bootPhase
    if $phase == null { die $"($file) sets no bootPhase line to put `power` after" }
    let phase_regex = '(?m)^([ \t]*)((?:vm\.)?)(bootPhase\s*=\s*"[^"]*"\s*;.*)$'
    $text | str replace --regex $phase_regex $"${1}${2}${3}\n${1}${2}power = \"($want)\";"
}

def "main status" []: nothing -> nothing {
    let guests = guests-load
    for phase in $PHASES {
        print $"($phase):"
        for guest in ($guests | where phase == $phase) { print $"  (guest-name $guest.source | fill --width $NAME_WIDTH) ($guest.power)" }
    }
}

# an unknown flag is a usage error like a typo in a phase, not nu's own parse error
def --wrapped main [...args: string]: nothing -> nothing {
    if ($args | length) not-in [2 3] or ($args | length) == 3 and $args.2 != "--apply" { usage }
    let phase = $args.0
    let want = $args.1
    let apply = ($args | length) == 3
    if $phase not-in $PHASES or $want not-in $STATES { usage }
    let edits = guests-load | where phase == $phase | each {|guest|
        let name = guest-name $guest.source | fill --width $NAME_WIDTH
        if $guest.power == $want {
            print $"  ($name) already ($guest.power)"
            return null
        }
        print $"  ($name) ($guest.power) -> ($want)"
        let file = $SRC | path join $guest.source
        {file: $file, text: (power-set (open --raw $file) $want $file)}
    } | compact
    if ($edits | is-empty) {
        print "nothing to change."
    } else if $apply {
        for edit in $edits { $edit.text | save --force $edit.file }
        print "instance files updated. Deploy with ./sync.nu"
    } else {
        print "dry run. Re-run with --apply to write the instance files."
    }
}
