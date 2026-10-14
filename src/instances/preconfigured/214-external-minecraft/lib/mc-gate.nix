# mc-gate (lib/mc-gate, its header says what it does): the package and the names the guest and its tests need.
# Nothing runs it yet; the units that do arrive with the several servers (spec-001 p3).
#
#   mcGate = import ./lib/mc-gate.nix { inherit pkgs lib; };
#   mcGate.package                      # the gate and its fake backend
#   lib.getExe mcGate.package           # the gate's binary
{ pkgs, lib }:
let
  # -----------------------------------------------------------------------------
  # CONSTANTS
  # -----------------------------------------------------------------------------

  # the go module's binaries: the gate itself, and the test backend its vm test runs instead of the image
  binary = "mc-gate";
  fakeServer = "fake-server";
in {
  inherit binary fakeServer;

  # go's standard library only; buildGoModule runs its tests (*_test.go) before anything ships
  package = pkgs.buildGoModule {
    pname = "mc-gate";
    version = "1.0.0";
    src = lib.fileset.toSource { root = ./mc-gate; fileset = ./mc-gate; };
    vendorHash = null;
    env.CGO_ENABLED = "0";
    meta.mainProgram = binary;
  };
}
