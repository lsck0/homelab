# a consistent copy of a live sqlite database, the one way db-backup.nix and local-state.nix take it
#
# The online backup api copies under a concurrent writer; a writer holding its lock makes the copy wait up to
# busyTimeoutMs instead of failing with "database is locked". No app holds a transaction for a minute, and the
# copies run at night, so waiting costs nothing.
#
#   sqliteBackup = import ./sqlite-backup.nix;
#   script = "${sqliteBackup.command "/var/lib/app/db.sqlite" "$tmp"}";   # shell: both arguments are expanded there
let
  busyTimeoutMs = 60000;
in {
  # command <source> <target>: shell words; the target is single-quoted inside sqlite's dot-command
  command = source: target: ''sqlite3 ${source} ".timeout ${toString busyTimeoutMs}" ".backup '${target}'"'';
}
