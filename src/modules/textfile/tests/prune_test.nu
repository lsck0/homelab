# lib/prune.nu as activation runs it, generation after generation, on a scratch textfile directory
#
# usage: prune_test.nu <textfile-prune executable>

def fail [message: string]: nothing -> nothing {
    print -e $"FAIL: ($message)"
    exit 1
}

def put [dir: path, ...names: string]: nothing -> nothing {
    $names | each {|name| "x 1\n" | save --force ($dir | path join $"($name).prom") } | ignore
}

def has [dir: path, name: string, why: string]: nothing -> nothing {
    if not ($dir | path join $"($name).prom" | path exists) { fail $"($why): ($name).prom is gone" }
}

def gone [dir: path, name: string, why: string]: nothing -> nothing {
    if ($dir | path join $"($name).prom" | path exists) { fail $"($why): ($name).prom is still there" }
}

def activate [prune: path, dir: path, ...patterns: string]: nothing -> nothing {
    let run = do { ^$prune $dir ...$patterns } | complete
    if $run.exit_code != 0 { fail $"activate ($patterns): exit ($run.exit_code): ($run.stderr)" }
}

def main [prune: path]: nothing -> nothing {
    let d = mktemp --directory | path join textfile
    mkdir $d

    # a host's first generation removes nothing: what nobody ever declared survives (a forgotten writer loses nothing)
    put $d app_builder ondemand forgotten
    activate $prune $d ondemand
    has $d app_builder "never recorded"
    has $d ondemand "declared"
    has $d forgotten "never declared"

    # the builder moved away: the name its old generation recorded goes, the others stay
    activate $prune $d app_builder ondemand
    has $d app_builder "declared"
    activate $prune $d ondemand
    gone $d app_builder "undeclared after being declared"
    has $d ondemand "still declared"

    # a runtime part: every file of a declared pattern stays, all of them go with the pattern, and a half-written one
    activate $prune $d ondemand 'swarm_app_*'
    put $d swarm_app_hello swarm_app_wat
    "x 1\n" | save --force ($d | path join swarm_app_gone.prom.tmp)
    activate $prune $d ondemand 'swarm_app_*'
    has $d swarm_app_hello "pattern still declared"
    has $d swarm_app_wat "pattern still declared"
    activate $prune $d ondemand
    gone $d swarm_app_hello "pattern undeclared"
    gone $d swarm_app_wat "pattern undeclared"
    if ($d | path join swarm_app_gone.prom.tmp | path exists) { fail "pattern undeclared: its .prom.tmp is still there" }

    # a host that declares nothing any more removes what it recorded, and the next run removes nothing
    activate $prune $d
    gone $d ondemand "nothing declared"
    put $d ondemand
    activate $prune $d
    has $d ondemand "recorded nothing last time"

    # the record itself is no metric, and a pattern never matches more than its own name
    activate $prune $d 'db_dump_*'
    put $d db_dump_paperless db_dumpling
    activate $prune $d
    gone $d db_dump_paperless "pattern undeclared"
    has $d db_dumpling "outside the pattern"
    if not ($d | path join .declared | path exists) { fail "no record" }

    # a pattern outside the option's shape is refused, not taken as a regex
    let bad = do { ^$prune $d 'a.b' } | complete
    if $bad.exit_code == 0 { fail "a pattern with a regex character was taken" }

    print "prune: ok"
}
