# mc-gate's package (the gate and its fake backend) and the binary names the guest and its tests need
{ pkgs, lib }:
let
  binary = "mc-gate";
  fakeServer = "fake-server";
in {
  inherit binary fakeServer;

  # buildGoModule runs the go tests before anything ships
  package = pkgs.buildGoModule {
    pname = "mc-gate";
    version = "1.0.0";
    src = lib.fileset.toSource { root = ./mc-gate; fileset = ./mc-gate; };
    vendorHash = null;
    env.CGO_ENABLED = "0";
    meta.mainProgram = binary;
  };
}
