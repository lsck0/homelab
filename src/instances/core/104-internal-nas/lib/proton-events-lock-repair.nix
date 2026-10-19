# proton-events-lock-repair.nu: the proton fronts and kopia-verify run it under the proton lock
{ pkgs }: pkgs.writers.writeNuBin "proton-events-lock-repair" (builtins.readFile ./proton-events-lock-repair.nu)
