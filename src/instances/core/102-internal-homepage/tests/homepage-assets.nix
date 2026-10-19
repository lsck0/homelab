# the homepage loads no asset from a third party: every icon and the background its yaml names is a file of a
# directory vm-102 mounts into homepage's public one, so a visit never reaches jsDelivr or Unsplash. Only the admins'
# page holds a widget or a credential: the page everybody else opens names none. A powered-off guest's card links
# nowhere: its route only answers 503.
{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  homepage = inputs.self.nixosConfigurations."102-internal-homepage".config;
  inherit (homepage.virtualisation.oci-containers) containers;
  # the generated yaml files of a page, each a store path (main.nix restartTriggers)
  yamlsOf =
    page:
    lib.filter (path: lib.hasSuffix ".yaml" path) (map toString homepage.systemd.services."podman-${page}".restartTriggers);
  yamls = lib.concatMap yamlsOf (lib.attrNames containers);
  plainPage = "start";
  publicDir = "/app/public";
  # "<source>:/app/public/<path>:ro" -> { <path> = <source>; }
  mounts = lib.listToAttrs (
    lib.concatMap (
      volume:
      let
        parts = lib.splitString ":" volume;
        target = builtins.unsafeDiscardStringContext (lib.elemAt parts 1);
      in
      lib.optional (lib.hasPrefix publicDir target) (lib.nameValuePair (lib.removePrefix publicDir target) (lib.head parts))
    ) containers.homepage.volumes
  );
  served = pkgs.linkFarm "homepage-public" (
    lib.mapAttrsToList (path: source: {
      name = lib.removePrefix "/" path;
      path = source;
    }) mounts
  );
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
  disabled=0
  for yaml in ${lib.escapeShellArgs yamls}; do
    disabled=$((disabled + $(grep -c '(disabled)' "$yaml" || true)))
    awk '/^-? *- /{ if (off && link) bad = 1; off = 0; link = 0 }
         /^ +description: .*\(disabled\)/{ off = 1 }
         /^ +href:/{ link = 1 }
         END{ if (off && link) bad = 1; exit bad }' "$yaml" \
      || { echo "$yaml: a powered-off guest's card links to its route" >&2; exit 1; }
  done
  [ "$disabled" -gt 0 ] || { echo "no powered-off guest's card to check" >&2; exit 1; }
  for yaml in ${lib.escapeShellArgs (yamlsOf plainPage)}; do
    if grep -nE '^ +widget:|HOMEPAGE_VAR_|openmeteo|resources:' "$yaml"; then
      echo "$yaml: the page for everybody shows a widget" >&2
      exit 1
    fi
  done
  ${lib.optionalString (containers.${plainPage}.environmentFiles != [ ]) ''
    echo "the page for everybody gets the widget credentials" >&2
    exit 1
  ''}
  echo "$found icons and images, all served by homepage itself"
  touch $out
''
