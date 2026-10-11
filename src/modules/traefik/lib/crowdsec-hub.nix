# crowdsec's rules: the hub as of one commit, the collections the ingresses install from it, and the data files their
# items name (the crs rules among them), from the lists repository hub-data.crowdsec.net serves; all offline
# (tests/crowdsec-hub.nix). cscli fetches an item's data only when it downloads the item, so a vendored hub needs
# them vendored too, or the waf runs without its rules.
{ pkgs, lib }:
let
  hub = pkgs.fetchFromGitHub {
    owner = "crowdsecurity";
    repo = "hub";
    rev = "f5cd0975d0bd69ebad09c5e6992d4f1a1ef594b0";
    hash = "sha256-CT3Fah8RSuKkL4MmeJP2aEiUFs/fG7oXQOuZFJUxaks=";
  };
  # the same week as the hub
  secLists = pkgs.fetchFromGitHub {
    owner = "crowdsecurity";
    repo = "sec-lists";
    rev = "0cbb1da40c8698c941d0bf7fd1c81567b1603e97";
    hash = "sha256-fk8GBiWYs9uJIkafl5xD9GFiSwx+1XqeDzDgdiF9kGQ=";
  };
  dataUrlPrefix = "https://hub-data.crowdsec.net/";
  collections = [
    "crowdsecurity/traefik"
    "crowdsecurity/http-cve"
    "crowdsecurity/appsec-virtual-patching"
    "crowdsecurity/appsec-generic-rules"
    "crowdsecurity/appsec-crs-inband"
  ];

  # a release names its own hub branch; a nix build asks version.crowdsec.net unless told
  cscliConfig = pkgs.writeText "config.yaml" (builtins.toJSON {
    common.log_media = "stdout";
    cscli.hub_branch = "master";
    config_paths = { config_dir = "@etc@"; data_dir = "@data@"; hub_dir = "@etc@/hub"; index_path = "@etc@/hub/.index.json"; };
  });

  # installs the collections into ./etc as the container's entrypoint does, without a network
  install = ''
    mkdir -p etc data
    cp -r --no-preserve=mode ${hub} etc/hub
    sed -e "s|@etc@|$PWD/etc|g" -e "s|@data@|$PWD/data|g" ${cscliConfig} > etc/config.yaml
    cscli -c etc/config.yaml collections install ${lib.escapeShellArgs collections} >/dev/null
  '';

  # every data file an installed item names, at its dest_file; a url outside the lists repository fails the build
  data = pkgs.runCommand "crowdsec-data" { nativeBuildInputs = [ pkgs.crowdsec pkgs.yq-go ]; } (install + ''
    mkdir $out
    find -L etc -path etc/hub -prune -o -name '*.yaml' -type f -print0 \
      | xargs -0 yq ea -N '.data[]? | [.source_url, .dest_file] | @tsv' \
      | sort -u | while IFS=$'\t' read -r url dest; do
        [[ $url == ${dataUrlPrefix}* ]] || { echo "data file outside ${dataUrlPrefix}: $url" >&2; exit 1; }
        install -m 0644 ${secLists}/''${url#${dataUrlPrefix}} "$out/$dest"
      done
  '');
in {
  inherit hub collections install data;
}
