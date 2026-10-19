# lab-wide: sync.nu's age key push around a switch (scripts/lib/host-age-key.nu)
# a rotated key never strands a guest: until settle, the key file holds the new key and every old identity, a
# failed switch (no settle) keeps them, a repeated push adds nothing, settle leaves the new key alone
{ pkgs, ... }:
pkgs.runCommand "host-age-key"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.nushell
    ];
  }
  ''
    export HOME=$TMPDIR
    run() { nu --no-config-file --stdin ${../scripts/lib/host-age-key.nu} "$1" keys/key.txt <<<"$2"; }
    expect() { [ "$(cat keys/key.txt)" = "$(printf '%s\n' "$@")" ] || { echo "key file: $(cat keys/key.txt), expected: $*"; exit 1; }; }

    [ "$(run push old)" = changed ]; expect old
    [ "$(stat -c %a keys/key.txt)" = 600 ] && [ "$(stat -c %a keys)" = 700 ]
    [ -z "$(run push old)" ]; expect old
    [ "$(run push new)" = changed ]; expect new old
    [ "$(run push new)" = changed ]; expect new old
    run settle new; expect new
    [ -z "$(run push new)" ]; expect new
    if run rotate other 2>/dev/null; then echo "an unknown action ran"; exit 1; fi
    expect new
    touch $out
  ''
