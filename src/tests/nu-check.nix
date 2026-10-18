# lab-wide: every nu script of the repo
# every *.nu of the repo (sync.nu, src/scripts, the guests' and tests' scripts) and the git hook parses under the nu
# the flake pins,
# which is the one the guests' writeNu scripts run: `nu --ide-check` reports each parse and type error as a
# diagnostic. Each file is checked from its own folder, where its relative `use` paths resolve. sync.nu lives at the
# repo's top, which only a git flake (git+file:...?dir=src) holds; a path: flake is refused.
{ pkgs, lib, ... }:
let
  repo = ../..;
  wholeRepo = builtins.pathExists (repo + "/sync.nu");
  scripts = lib.fileset.toSource {
    root = repo;
    fileset = lib.fileset.unions [ (repo + "/.githooks") (lib.fileset.fileFilter (f: f.hasExt "nu") repo) ];
  };
  # the most diagnostics one file reports
  diagnosticsMax = 100;
in
assert lib.assertMsg wholeRepo
  "nu-check needs the whole repo (sync.nu): build it from git, `nix build ./src#checks.x86_64-linux.nu-check`, not from a path: flake";
pkgs.runCommand "nu-check" { nativeBuildInputs = [ pkgs.nushell pkgs.findutils pkgs.gnugrep ]; } ''
  export HOME=$TMPDIR
  failed=0
  count=0
  while IFS= read -r -d "" f; do
    count=$((count + 1))
    found=$(cd "${scripts}/$(dirname "$f")" && nu --no-config-file --ide-check ${toString diagnosticsMax} "$(basename "$f")" | grep '"type":"diagnostic"' || true)
    if [ -n "$found" ]; then
      echo "$f:"
      echo "$found"
      failed=1
    fi
  done < <(cd ${scripts} && find . -type f \( -name '*.nu' -o -path './.githooks/*' \) -print0 | sort -z)
  [ "$failed" = 0 ]
  echo "nu-check: $count scripts parse under nu ${pkgs.nushell.version}"
  touch $out
''
