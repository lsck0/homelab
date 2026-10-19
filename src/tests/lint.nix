# lab-wide: ruff check, go vet, deadnix and statix find nothing
# statix's repeated_keys and faster_groupby are off: the repo sets `systemd.services.x` and `systemd.timers.x` apart on
# purpose, and lib.groupBy is builtins.groupBy.
{ pkgs, lib, ... }:
let
  sources = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.fileFilter (
      f:
      f.name == "go.mod"
      || lib.any f.hasExt [
        "nix"
        "py"
        "go"
      ]
    ) ../.;
  };
  # the nixos test driver defines Machine, and lab.testScript LABPROBE, before the preludes in tests/lib run
  ruffConfig = ''builtins = ["Machine", "LABPROBE"]'';
  statixConfig = pkgs.writeText "statix.toml" ''
    disabled = ["repeated_keys", "faster_groupby"]
  '';
in
pkgs.runCommand "lint"
  {
    nativeBuildInputs = [
      pkgs.ruff
      pkgs.go
      pkgs.statix
      pkgs.deadnix
      pkgs.findutils
    ];
    # go's standard library only: no cgo, no toolchain download
    env = {
      CGO_ENABLED = "0";
      GOTOOLCHAIN = "local";
    };
  }
  ''
    export HOME=$TMPDIR GOCACHE=$TMPDIR/go-cache
    cd ${sources}
    failed=0
    ruff check --no-cache --output-format concise --config '${ruffConfig}' . || failed=1
    while IFS= read -r -d "" module; do
      (cd "$(dirname "$module")" && go vet ./...) || failed=1
    done < <(find . -name go.mod -print0 | sort -z)
    deadnix --fail . || failed=1
    statix check --format errfmt --config ${statixConfig} . || failed=1
    [ "$failed" = 0 ]
    touch $out
  ''
