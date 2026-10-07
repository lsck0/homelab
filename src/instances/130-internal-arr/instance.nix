# *arr stack: prowlarr + flaresolverr, radarr, sonarr, lidarr, bazarr, recyclarr
{ lib, ... }:
let
  # each api key is <name>-key: a sops secret the servarr apps take from their environment (lib/servarr.nix), a lab
  # token bazarr mints itself; hermes' skill of the same name calls the api
  arrs = {
    bazarr = { port = 6767; description = "Subtitles"; minted = true; };
    lidarr = { port = 8686; description = "Music"; minted = false; };
    prowlarr = { port = 9696; description = "Indexers (Tor)"; minted = false; };
    radarr = { port = 7878; description = "Movies"; minted = false; };
    sonarr = { port = 8989; description = "Series & anime"; minted = false; };
  };
  keyOf = name: "${name}-key";
  # where a widget finds the key: the token share, or sops
  keySource = arr: if arr.minted then "tokens" else "secrets";
in {
  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    # five .net apps plus flaresolverr's chromium: 1510 MiB peak over 7d, which the floor holds; they thrashed
    # below a 512 floor each
    memoryMiB = 3072;
    balloonMiB = 1536;
    diskGiB = 16;
  };

  grants = lib.mapAttrsToList (name: arr: { from = [ "operator" ]; tcp = [ arr.port ]; why = "hermes' ${name} skill calls the api"; }) arrs;

  tokens = map keyOf (lib.attrNames (lib.filterAttrs (_: arr: arr.minted) arrs));

  services = lib.mapAttrs (name: arr: {
    inherit (arr) port;
    homepage = {
      inherit (arr) description;
      group = "Media";
      icon = name;
      widget = { ${keySource arr}.key = keyOf name; type = name; };
    };
  }) arrs;

  tokenReads = [ "jellyfin-key-arr" ];

  shares = {
    bulk = { };
    "data/bazarr" = { };
    "data/lidarr" = { };
    "data/prowlarr" = { };
    "data/radarr" = { };
    "data/sonarr" = { };
  };
}
