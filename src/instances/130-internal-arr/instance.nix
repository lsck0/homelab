# *arr stack: prowlarr + flaresolverr, radarr, sonarr, lidarr, bazarr, recyclarr
{ lib, ... }:
let
  # each exports its api key as <name>-key; hermes' skill of the same name calls its api
  arrs = {
    bazarr = { port = 6767; description = "Subtitles"; };
    lidarr = { port = 8686; description = "Music"; };
    prowlarr = { port = 9696; description = "Indexers (Tor)"; };
    radarr = { port = 7878; description = "Movies"; };
    sonarr = { port = 8989; description = "Series & anime"; };
  };
  keyOf = name: "${name}-key";
in {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    # five .net apps plus flaresolverr's chromium: 1510 MiB peak over 7d; they thrashed below a 512 floor each
    memoryMiB = 3072;
    balloonMiB = 2048;
    diskGiB = 16;
  };

  grants = lib.mapAttrsToList (name: arr: { from = [ "114" ]; tcp = [ arr.port ]; why = "hermes' ${name} skill calls the api"; }) arrs;

  tokens = map keyOf (lib.attrNames arrs);

  services = lib.mapAttrs (name: arr: {
    inherit (arr) port;
    homepage = {
      inherit (arr) description;
      group = "Media";
      icon = name;
      widget = { tokens.key = keyOf name; type = name; };
    };
  }) arrs;
}
