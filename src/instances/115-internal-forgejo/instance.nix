# git forge (OIDC + SSH); its ci runner lives on 117
{ ... }: {
  vm = {
    bootPhase = "dev";
    needs = [ "containers" "nfs" ];
    memoryMiB = 2048;
    # sized when the runner's job images lived here too; terraform cannot shrink a disk
    diskGiB = 24;
  };

  tokens = [ "forgejo-hermes" "forgejo-key" "forgejo-runner" ];

  services = {
    forgejo = {
      host = "git";
      port = 80;
      loginRedirect = { path = "/user/login"; to = "/user/oauth2/authelia"; };
      homepage = {
        group = "Dev";
        icon = "forgejo";
        widget = { tokens = { key = "forgejo-key"; }; type = "gitea"; };
      };
      oidc = {
        callback = "/user/oauth2/authelia/callback";
        name = "Forgejo";
        pkce = false;
        tokenAuthMethod = "client_secret_basic";
      };
      off = {
        sso = "logs in itself through authelia oidc; git clients use tokens and ssh";
        anubis = "git clients run no proof of work";
        waf = "git packs the rules misread";
        bodyLimit = "git pushes and attachments";
      };
    };
  };
}
