# lib/crowdsec-hub.nix: the ingresses' collections install from the vendored hub without a network (the sandbox has
# none), and every data file their items name is vendored, the crs rules of the waf among them
{ pkgs, lib, ... }:
let
  crowdsecHub = import ../lib/crowdsec-hub.nix { inherit pkgs lib; };
  # the crs rule set's last phase, a file the waf cannot block without
  crsRules = "REQUEST-949-BLOCKING-EVALUATION.conf";
in
pkgs.runCommand "crowdsec-hub" { nativeBuildInputs = [ pkgs.crowdsec pkgs.jq pkgs.yq-go ]; } (crowdsecHub.install + ''
  # list shows the installed ones only
  installed=$(cscli -c etc/config.yaml collections list -o json)
  for collection in ${lib.escapeShellArgs crowdsecHub.collections}; do
    jq -e --arg c "$collection" '.collections[] | select(.name == $c)' <<<"$installed" >/dev/null \
      || { echo "$collection is not installed"; exit 1; }
  done
  named=$(find -L etc -path etc/hub -prune -o -name '*.yaml' -type f -print0 | xargs -0 yq ea -N '.data[]?.dest_file' | sort -u)
  vendored=$(ls ${crowdsecHub.data} | sort)
  [ "$named" = "$vendored" ] || { echo "data files named and vendored differ:"; diff <(echo "$named") <(echo "$vendored"); exit 1; }
  [ -s ${crowdsecHub.data}/${crsRules} ] || { echo "the crs rules are not vendored"; exit 1; }
  echo "${toString (lib.length crowdsecHub.collections)} collections and $(wc -l <<<"$vendored") data files install offline" > $out
'')
