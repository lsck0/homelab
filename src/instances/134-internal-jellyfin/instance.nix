# media streaming + Janitorr (deletes media unwatched for months)
{ lib, site, ... }:
let
  port = 80;
  ollama = import ../../modules/ollama.nix;
in {
  # ollama on the site's gpu (modules/ollama.nix)
  roles = [ "llm" ];

  vm = {
    bootPhase = "media";
    needs = [ "containers" "nfs" ];
    # vfio pins all ram, so no balloon
    memoryMiB = 3072;
    balloonMiB = 0;
    cores = 4;
    # ollama model 4.4G beside jellyfin
    diskGiB = 24;
    machine = "q35";
    pci = lib.optional (site.gpu != null) "gpu";
  };

  # one api key per consumer, so a leaked one is revoked alone
  tokens = [ "jellyfin-key-homepage" "jellyfin-key-hermes" "jellyfin-key-arr" "jellyfin-key-janitorr" ];

  # janitorr's own jellyfin user, set once by the setup
  secrets = { janitorr-pass = "guardsData:hex:16"; };

  grants = [
    { from = [ "operator" "128" "130" ]; tcp = [ port ]; why = "hermes, jellyseerr and the arrs' notifications call its api directly"; }
    { from = [ "121" ]; tcp = [ ollama.port ]; why = "paperless-ai asks the local llm"; }
  ];

  services = {
    jellyfin = {
      inherit port;
      loginPaths = [ "/Users/AuthenticateByName" ];
      loginRedirect = { path = "/"; to = "/sso/OID/start/authelia"; };
      frames = "sameorigin";
      guest = true;
      homepage = {
        description = "Movies & shows";
        group = "Media";
        icon = "jellyfin";
        widget = {
          settings = { enableBlocks = true; enableNowPlaying = true; version = 2; };
          tokens = { key = "jellyfin-key-homepage"; };
          type = "jellyfin";
        };
      };
      oidc = {
        callback = "/sso/OID/redirect/authelia";
        name = "Jellyfin";
        pkce = false;
        tokenAuthMethod = "client_secret_post";
      };
      off = {
        sso = "logs in itself through authelia oidc (sso plugin); apps use quick connect";
        anubis = "the jellyfin apps run no proof of work";
        bodyLimit = "image and plugin uploads";
      };
    };
  };

  tokenReads = [ "jellyseerr-key" ];

  shares = {
    bulk = { };
    "data/janitorr" = { };
    "data/jellyfin" = { };
  };
}
