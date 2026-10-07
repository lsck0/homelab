# labprobe (lib/labprobe.py) as a command; lab.nix puts it on every lab node
{ pkgs }:
# the repo's 120 columns, not flake8's 79
pkgs.writers.writePython3Bin "labprobe" { flakeIgnore = [ "E501" ]; } (builtins.readFile ./labprobe.py)
