# git forge (OIDC + SSH); its ci runner lives on 111
{
  lib,
  id,
  profiles,
  ...
}:
{
  vm = {
    # parked while unused; "on" brings it back
    power = "off";
    bootPhase = "dev";
    needs = [
      "containers"
      "nfs"
    ];
    memoryMiB = 2048;
    # forgejo idles in a few hundred MiB; the rest is page cache the balloon may take
    balloonMiB = 768;
    # sized when the runner's job images lived here too; terraform cannot shrink a disk
    diskGiB = 24;
  };

  grants = [
    {
      from = [
        "lan"
        "wireguard"
      ];
      tcp = [ (import ./lib/git-ssh.nix).port ];
      why = "git over ssh: the house and the owner's devices";
    }
  ];

  tokens = [
    "forgejo-hermes"
    "forgejo-key"
    "forgejo-runner"
  ];

  services = {
    forgejo = {
      host = "git";
      port = 80;
      loginRedirect = {
        path = "/user/login";
        to = "/user/oauth2/authelia";
      };
      homepage = {
        group = "Dev";
        icon = "forgejo";
        widget = {
          tokens = {
            key = "forgejo-key";
          };
          type = "gitea";
        };
      };
      oidc = {
        callback = "/user/oauth2/authelia/callback";
        name = "Forgejo";
        pkce = false;
        tokenAuthMethod = "client_secret_basic";
      };
      # logs in itself through authelia oidc; git clients use tokens, solve no captcha, push packs the waf misreads
      on =
        lib.subtractLists [ "sso" "captcha" "waf" "bodyLimit" ] profiles.hardenedInternal
        ++ profiles.listed
        ++ profiles.observed;
    };
  };

  shares = {
    "data/db-dumps/vm-${id}" = {
      mode = "0700";
    };
    "data/forgejo".localState = true;
  };
}
