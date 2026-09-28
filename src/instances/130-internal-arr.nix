# the *arr media stack, one app per port (routes.nix)
{ ... }: {
  imports = [
    ../services/prowlarr.nix
    ../services/radarr.nix
    ../services/sonarr.nix
    ../services/lidarr.nix
    ../services/bazarr.nix
    ../services/recyclarr.nix
  ];

  networking.hostName = "vm-130";
}
