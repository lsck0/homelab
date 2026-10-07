# the placement control's fixture (tests/policy-controls.nix): a test of 100 that tests a file of 101 as well
{ }: [ (import ../main.nix) (import ../../101-internal-b/main.nix) ]
