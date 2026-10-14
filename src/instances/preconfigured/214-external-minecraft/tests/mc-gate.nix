# mc-gate's go tests: the package, whose buildGoModule check phase runs them, and a fuzz run of the frame reader the
# internet talks to first. Both are offline and run no unit; the gate's behaviour on a guest is the minecraft test's.
{ pkgs, lib, ... }:
let
  mcGate = import ../lib/mc-gate.nix { inherit pkgs lib; };

  # the frame reader is the one parser an unauthenticated stranger reaches: fuzz it, with the table's inputs as seeds
  fuzzTarget = "Fuzz_spec001_r040_frame";
  fuzzSeconds = 30;
  fuzz = pkgs.runCommand "mc-gate-fuzz" { nativeBuildInputs = [ pkgs.go ]; } ''
    cp -r ${mcGate.package.src} module && chmod -R u+w module && cd module
    export HOME=$TMPDIR GOCACHE=$TMPDIR/cache GOPATH=$TMPDIR/path GOFLAGS=-mod=mod GOPROXY=off CGO_ENABLED=0
    go test -run '^$' -fuzz=${fuzzTarget} -fuzztime=${toString fuzzSeconds}s .
    touch $out
  '';
in
pkgs.linkFarm "mc-gate" [
  { name = "spec001_r059"; path = mcGate.package; }
  { name = "spec001_r040-fuzz"; path = fuzz; }
]
