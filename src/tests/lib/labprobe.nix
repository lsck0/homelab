# labprobe (lib/labprobe.py) as a command; lab.nix puts it on every lab node
{ pkgs }:
# the repo's 120 columns, and ruff format's slices (E203) and operator line breaks (W503)
pkgs.writers.writePython3Bin "labprobe" {
  flakeIgnore = [
    "E501"
    "E203"
    "W503"
  ];
} (builtins.readFile ./labprobe.py)
