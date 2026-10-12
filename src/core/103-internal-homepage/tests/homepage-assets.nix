# the homepage loads no asset from a third party: every icon and the background its yaml names is a file of a
# directory vm-103 mounts into homepage's public one, so a visit never reaches jsDelivr or Unsplash
{ pkgs, lib, inputs, ... }:
let
  homepage = inputs.self.nixosConfigurations."103-internal-homepage".config;
  # the generated yaml files, each a store path (main.nix restartTriggers)
  yamls = lib.filter (path: lib.hasSuffix ".yaml" path) (map toString homepage.systemd.services.podman-homepage.restartTriggers);
  publicDir = "/app/public";
  # "<source>:/app/public/<path>:ro" -> { <path> = <source>; }
  mounts = lib.listToAttrs (lib.concatMap (volume: let
    parts = lib.splitString ":" volume;
    target = builtins.unsafeDiscardStringContext (lib.elemAt parts 1);
  in lib.optional (lib.hasPrefix publicDir target) (lib.nameValuePair (lib.removePrefix publicDir target) (lib.head parts)))
    homepage.virtualisation.oci-containers.containers.homepage.volumes);
  served = pkgs.linkFarm "homepage-public" (lib.mapAttrsToList (path: source: { name = lib.removePrefix "/" path; path = source; }) mounts);
in
pkgs.runCommand "homepage-assets" { } ''
  found=0
  for yaml in ${lib.escapeShellArgs yamls}; do
    if grep -nE 'jsdelivr|unsplash' "$yaml"; then
      echo "$yaml names a third-party asset" >&2
      exit 1
    fi
    while read -r asset; do
      found=$((found + 1))
      case "$asset" in
        /*) [ -e "${served}$asset" ] || { echo "$yaml: $asset is not among the served files" >&2; exit 1; } ;;
        *) echo "$yaml: $asset is resolved by homepage from a cdn" >&2; exit 1 ;;
      esac
    done < <(sed -nE 's/^ *(icon|image): *"?([^"]*)"?$/\2/p' "$yaml")
  done
  [ "$found" -gt 0 ] || { echo "no icon or image found in ${toString yamls}" >&2; exit 1; }
  echo "$found icons and images, all served by homepage itself"
  touch $out
''
