# lib/crowdsec-hub.nix: the ingresses' collections install from the vendored hub without a network (the sandbox has none)
{ pkgs, lib, ... }:
let
  crowdsecHub = import ../lib/crowdsec-hub.nix { inherit pkgs; };
  # a release names its own hub branch; a nix build asks version.crowdsec.net unless told
  config = pkgs.writeText "config.yaml" (builtins.toJSON {
    common.log_media = "stdout";
    cscli.hub_branch = "master";
    config_paths = { config_dir = "@etc@"; data_dir = "@data@"; hub_dir = "@etc@/hub"; index_path = "@etc@/hub/.index.json"; };
  });
in
pkgs.runCommand "crowdsec-hub" { nativeBuildInputs = [ pkgs.crowdsec pkgs.jq ]; } ''
  mkdir -p etc data
  cp -r --no-preserve=mode ${crowdsecHub.hub} etc/hub
  sed -e "s|@etc@|$PWD/etc|g" -e "s|@data@|$PWD/data|g" ${config} > etc/config.yaml
  cscli -c etc/config.yaml collections install ${lib.escapeShellArgs crowdsecHub.collections}
  # list shows the installed ones only
  installed=$(cscli -c etc/config.yaml collections list -o json)
  for collection in ${lib.escapeShellArgs crowdsecHub.collections}; do
    jq -e --arg c "$collection" '.collections[] | select(.name == $c)' <<<"$installed" >/dev/null \
      || { echo "$collection is not installed"; exit 1; }
  done
  echo "${toString (lib.length crowdsecHub.collections)} collections install offline" > $out
''
