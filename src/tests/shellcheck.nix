# lab-wide: every shell script of the repo
# every shell script of the repo passes shellcheck at its strictest default (style notes included): sync.sh, the
# hook, src/scripts, the instances' and the modules' scripts and the test scripts. A disabled check carries its
# reason in a directive next to the code.
#
# The repo's top (sync.sh, the hook) is in the flake's source only when it is evaluated from git
# (git+file:...?dir=src copies the whole repo); a path: flake holds src alone, and then src's scripts are checked.
# Either way they sit at src/ in the checked tree, so the `source=` directives (relative to the repo root) resolve.
{ pkgs, lib, ... }:
let
  repo = ../..;
  wholeRepo = builtins.pathExists (repo + "/sync.sh");
  srcScripts = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "sh") ../scripts)
      (lib.fileset.fileFilter (f: f.hasExt "sh") ../instances)
      (lib.fileset.fileFilter (f: f.hasExt "sh") ../modules)
      (lib.fileset.fileFilter (f: f.hasExt "sh") ./.)
    ];
  };
  topScripts = lib.fileset.toSource {
    root = repo;
    fileset = lib.fileset.unions [ (repo + "/sync.sh") (repo + "/.githooks") ];
  };
in
pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck pkgs.findutils ]; } ''
  mkdir tree && cd tree
  cp -r ${srcScripts} src
  ${lib.optionalString wholeRepo "cp -r ${topScripts}/. ."}
  # -x follows the sourced libraries, whose paths the `source=` directives give relative to the repo root
  find . -type f \( -name '*.sh' -o -path './.githooks/*' \) -print0 | sort -z | xargs -0 shellcheck -x
  echo "shellcheck: $(find . -type f \( -name '*.sh' -o -path './.githooks/*' \) | wc -l) scripts clean"
  touch $out
''
