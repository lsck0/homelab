{ lib, profiles, ... }: {
  enable = true;
  repo = "lsck0/university";
  branch = "master";
  watch = [ "notes" ];
  static = {
    command = "nu notes/html/build.nu";
    output = "notes/dist";
    packages = pkgs: [
      (pkgs.texlive.combine {
        inherit (pkgs.texlive)
          scheme-medium
          collection-latexextra
          collection-bibtexextra
          ifptex
          ;
      })
      pkgs.nushell
      pkgs.graphviz
      pkgs.poppler-utils
      pkgs.ghostscript
    ];
  };
  schedule = "*-*-* 00:00:00 Europe/Berlin";
  routes.math = {
    indexable = true;
    on = lib.subtractLists [ "captcha" ] profiles.hardenedExternal ++ [ "probe" ];
  };
  homepage = {
    name = "Math";
    group = "Public";
    icon = "mdi-sigma";
  };
  resources.web.memoryMiB = 64;
  reservation.memoryMiB = 64;
  on = profiles.observed ++ [ "homepage" ];
}
