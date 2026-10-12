# the placement control's fixture (tests/policy-controls.nix): a test of 100 that tests a lib file of 101 as well
{ }: [ (import ../main.nix) (import ../../101-internal-b/lib/b.nix) ]
