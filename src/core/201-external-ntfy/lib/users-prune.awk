# `ntfy user list` on stdin -> the accounts ntfy-users-prune removes, one per line: those neither declared in main.nix
# (-v declared="<name> ...") nor marked by ntfy as its server config's
#
# An account is the line "user <name> (role: <role>, tier: <tier>[, server config])", its grants follow as "- ..."
# lines; `*` is the anonymous user. The mark alone is not enough: ntfy marks a declared account made by hand before
# it was declared only once the server provisions it, and then `ntfy user remove` refuses it.
BEGIN { split(declared, names, " "); for (i in names) isDeclared[names[i]] = 1 }
$1 == "user" && $2 != "*" && !($2 in isDeclared) && !/, server config\)$/ { print $2 }
