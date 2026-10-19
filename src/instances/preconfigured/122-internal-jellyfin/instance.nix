# media streaming + Janitorr (finds media unwatched for months; deletes it only with homelab.janitorr.deleteMedia)
{
  lib,
  site,
  profiles,
  ...
}:
let
  port = 80;
  ollama = import ../../../modules/ollama.nix;
in
{
  # ollama on the site's gpu (modules/ollama.nix)
  roles = [ "llm" ];

  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "media";
    needs = [
      "containers"
      "nfs"
    ];
    # vfio pins all ram, so no balloon
    memoryMiB = 3072;
    balloonMiB = 0;
    cores = 4;
    # ollama's model (modules/ollama.nix) beside jellyfin
    diskGiB = 24;
    machine = "q35";
    pci = lib.optional (site.gpu != null) "gpu";
  };

  # one api key per consumer, so a leaked one is revoked alone
  tokens = [
    "jellyfin-key-homepage"
    "jellyfin-key-hermes"
    "jellyfin-key-arr"
    "jellyfin-key-janitorr"
  ];

  # janitorr's own jellyfin user, set once by the setup
  secrets = {
    janitorr-pass = "guardsData:hex:16";
  };

  grants = [
    {
      from = [
        "operator"
        "123"
        "121"
      ];
      tcp = [ port ];
      why = "hermes, jellyseerr and the arrs' notifications call its api directly";
    }
    {
      from = [ "131" ];
      tcp = [ ollama.port ];
      why = "paperless-ai asks the local llm";
    }
  ];

  services = {
    jellyfin = {
      inherit port;
      loginPaths = [ "/Users/AuthenticateByName" ];
      loginRedirect = {
        path = "/";
        to = "/sso/OID/start/authelia";
      };
      frames = "sameorigin";
      guest = true;
      homepage = {
        description = "Movies & shows";
        group = "Media";
        icon = "jellyfin";
        widget = {
          settings = {
            enableBlocks = true;
            enableNowPlaying = true;
            version = 2;
          };
          tokens = {
            key = "jellyfin-key-homepage";
          };
          type = "jellyfin";
        };
      };
      oidc = {
        callback = "/sso/OID/redirect/authelia";
        name = "Jellyfin";
        pkce = false;
        tokenAuthMethod = "client_secret_post";
      };
      # logs in itself through authelia oidc (sso plugin); the apps use quick connect, solve no captcha and fetch a
      # library's posters in bursts; image and plugin uploads
      on =
        lib.subtractLists [ "sso" "captcha" "anonymousLimit" "bodyLimit" ] profiles.hardenedInternal
        ++ profiles.listed
        ++ profiles.observed;
    };
  };

  shares = {
    bulk = { };
    "data/janitorr" = { };
    "data/jellyfin".localState = true;
  };
}
