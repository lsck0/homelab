# the rendered searxng settings keep wikipedia off and wikidata on: the vpn exit gets wikipedia 429'd, wikidata
# carries the infobox in its place
{
  pkgs,
  inputs,
  ...
}:
let
  searxng = inputs.self.nixosConfigurations."211-external-searxng".config;
  preStart = pkgs.writeText "searxng-prestart" searxng.systemd.services.podman-searxng.preStart;
in
pkgs.runCommand "searxng-engines" { nativeBuildInputs = [ pkgs.yq-go ]; } ''
  settings=$(grep -o '/nix/store/[^ ]*-searxng-settings.yml' ${preStart} | head -n 1)
  [ -n "$settings" ] || { echo "the preStart renders no searxng-settings.yml" >&2; exit 1; }
  disabledOf() { yq ".engines[] | select(.name == \"$1\") | .disabled" "$settings"; }
  [ "$(disabledOf wikipedia)" = true ] || { echo "wikipedia is not disabled" >&2; exit 1; }
  [ "$(disabledOf wikidata)" != true ] || { echo "wikidata is disabled" >&2; exit 1; }
  [ -n "$(yq '.engines[] | select(.name == "wikidata") | .name' "$settings")" ] || { echo "wikidata is not configured" >&2; exit 1; }
  touch $out
''
