# every address range that is never the internet: the lab's private ranges and the tailnet (modules/net.nix). Code
# that lets a stranger's process reach the internet but nothing inside the lab (ci jobs, swarm tasks) refuses these
# and permits named exceptions in front of them.
#
#   privateRanges = import ./private-ranges.nix { inherit lib inventory site; };
{ lib, inventory, site }:
let
  net = import ./net.nix { inherit lib inventory site; };
in
net.privateRanges ++ [ net.tailnet ]
