# lib/crowdsec-local-config.nix as crowdsec merges it over the stock config.yaml (the image's flushes at 5000 alerts
# too): the deception's ban history is not flushed at the stock cap, and the use_wal beside it survives the merge
{ pkgs, lib, ... }:
let
  localConfig = import ../lib/crowdsec-local-config.nix {
    inherit pkgs lib;
    metricsPort = 6060;
  };
in
pkgs.runCommand "crowdsec-local-config"
  {
    nativeBuildInputs = [
      pkgs.crowdsec
      pkgs.yq-go
    ];
  }
  ''
    # its paths into the sandbox, where cscli creates them
    sed -e "s|/etc/|$PWD/etc/|g" -e "s|/var/|$PWD/var/|g" ${pkgs.crowdsec}/share/crowdsec/config/config.yaml > config.yaml
    cp ${localConfig} config.yaml.local
    merged=$(cscli -c config.yaml config show-yaml)
    [ "$(yq '.db_config.flush.max_items' <<<"$merged")" = 20000 ] || { echo "flush cap not raised: $merged"; exit 1; }
    [ "$(yq '.db_config.flush.max_age' <<<"$merged")" = 7d ] || { echo "flush age lost: $merged"; exit 1; }
    [ "$(yq '.db_config.use_wal' <<<"$merged")" = true ] || { echo "use_wal lost: $merged"; exit 1; }
    [ "$(yq '.db_config.type' <<<"$merged")" = sqlite ] || { echo "the merge dropped the stock db_config: $merged"; exit 1; }
    touch $out
  ''
